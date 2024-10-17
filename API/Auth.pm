package Plugins::TIDAL_test::API::Auth;

use strict;
use Data::URIEncode qw(complex_to_query);
use JSON::XS::VersionOneAndTwo;
use MIME::Base64 qw(encode_base64);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::TIDAL_test::API qw(AURL KURL SCOPES GRANT_TYPE_DEVICE);

use constant TOKEN_PATH => '/v1/oauth2/token';

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.tidal');
my $prefs = preferences('plugin.tidal');

my (%deviceCodes, $cid, $sec);

sub init {
	my $class = shift;
	$cid = $prefs->get('cid');
	$sec = $prefs->get('sec');

	$class->_fetchKs() unless $cid && $sec;
}

sub initDeviceFlow {
	my ($class, $cb) = @_;

	$class->_call('/v1/oauth2/device_authorization', $cb, {
		scope => SCOPES
	});
}

sub pollDeviceAuth {
	my ($class, $args, $cb) = @_;

	my $deviceCode = $args->{deviceCode} || return $cb->();

	$deviceCodes{$deviceCode} ||= $args;
	$args->{expiry} ||= time() + $args->{expiresIn};
	$args->{cb}     ||= $cb if $cb;

	_delayedPollDeviceAuth($deviceCode, $args);
}

sub _delayedPollDeviceAuth {
	my ($deviceCode, $args) = @_;

	Slim::Utils::Timers::killTimers($deviceCode, \&_delayedPollDeviceAuth);

	if ($deviceCodes{$deviceCode} && time() <= $args->{expiry}) {
		__PACKAGE__->_call(TOKEN_PATH, sub {
			my $result = shift;

			if ($result) {
				if ($result->{error}) {
					Slim::Utils::Timers::setTimer($deviceCode, time() + ($args->{interval} || 2), \&_delayedPollDeviceAuth, $args);
					return;
				}
				else {
					_storeTokens($result)
				}

				delete $deviceCodes{$deviceCode};
			}

			$args->{cb}->($result) if $args->{cb};
		},{
			scope => SCOPES,
			grant_type => GRANT_TYPE_DEVICE,
			device_code => $deviceCode,
		});

		return;
	}

	# we have timed out
	main::INFOLOG && $log->is_info && $log->info("we have timed out polling for an access token");
	delete $deviceCodes{$deviceCode};

	return $args->{cb}->() if $args->{cb};

	$log->error('no callback defined?!?');
}

sub cancelDeviceAuth {
	my ($class, $deviceCode) = @_;

	return unless $deviceCode;

	Slim::Utils::Timers::killTimers($deviceCode, \&_delayedPollDeviceAuth);
	delete $deviceCodes{$deviceCode};
}

sub _fetchKs {
	my ($class) = @_;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

			my $keys = $result->{keys};

			if ($keys) {
				$keys = [ sort {
					$b->{valid} <=> $a->{valid}
				} grep {
					$_->{cid} && $_->{sec} && $_->{valid}
				} map {
					{
						cid => $_->{clientId},
						sec => $_->{clientSecret},
						valid => $_->{valid} =~ /true/i ? 1 : 0
					}
				} grep {
					$_->{formats} =~ /Normal/
				} @$keys ];

				if (my $key = shift @$keys) {
					$cid = $key->{cid};
					$sec = $key->{sec};
					$prefs->set('cid', $cid);
					$prefs->set('sec', $sec);
				}
			}
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));
		}
	)->get(KURL);
}

sub refreshToken {
	my ( $class, $cb, $userId ) = @_;

	my $accounts = $prefs->get('accounts') || {};
	my $profile  = $accounts->{$userId};

	if ( $profile && (my $refreshToken = $profile->{refreshToken}) ) {
		$class->_call(TOKEN_PATH, sub {
			$cb->(_storeTokens(@_));
		},{
			grant_type => 'refresh_token',
			refresh_token => $refreshToken,
		});
	}
	else {
		$log->error('Did find neither access nor refresh token. Please re-authenticate.');
		# TODO expose warning on client
		$cb->();
	}
}

sub _storeTokens {
	my ($result) = @_;

	if ($result->{user} && $result->{user_id} && $result->{access_token}) {
		my $accounts = $prefs->get('accounts');

		my $userId = $result->{user_id};

		# have token expire a little early
		$cache->set("tidal_at_$userId", $result->{access_token}, $result->{expires_in} - 300);

		$result->{user}->{refreshToken} = $result->{refresh_token} if $result->{refresh_token};
		my %account = (%{$accounts->{$userId} || {}}, %{$result->{user}});
		$accounts->{$userId} = \%account;

		$prefs->set('accounts', $accounts);
	}

	return $result->{access_token};
}

sub _call {
	my ( $class, $url, $cb, $params ) = @_;

	my $bearer = encode_base64(sprintf('%s:%s', $cid, $sec));
	$bearer =~ s/\s//g;

	$params->{client_id} ||= $cid;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($response));
			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($result));

			$cb->($result);
		},
		sub {
			my ($http, $error) = @_;

			$log->error("Error: $error");
			main::INFOLOG && $log->is_info && !$log->is_debug && $log->info(Data::Dump::dump($http->contentRef));
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));

			$cb->({
				error => $error || 'failed auth request'
			});
		},
		{
			timeout => 15,
			cache => 0,
			expiry => 0,
		}
	)->post(AURL . $url,
		'Content-Type' => 'application/x-www-form-urlencoded',
		'Authorization' => 'Basic ' . $bearer,
		complex_to_query($params),
	);
}

1;