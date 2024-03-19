package Plugins::TIDAL::Plugin;

use strict;
use Async::Util;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::TIDAL::API::Async;
use Plugins::TIDAL::API::Auth;
use Plugins::TIDAL::ProtocolHandler;

my $log = Slim::Utils::Log->addLogCategory({
	'category'    => 'plugin.tidal',
	'description' => 'PLUGIN_TIDAL_NAME',
});

my $prefs = preferences('plugin.tidal');

sub initPlugin {
	my $class = shift;

	$prefs->init({
		quality => 'HIGH',
	});

	Plugins::TIDAL::API::Auth->init();

	if (main::WEBUI) {
		require Plugins::TIDAL::Settings;
		require Plugins::TIDAL::Settings::Auth;
		Plugins::TIDAL::Settings->new();
		Plugins::TIDAL::Settings::Auth->new();
	}

	Slim::Player::ProtocolHandlers->registerHandler('tidal', 'Plugins::TIDAL::ProtocolHandler');
	Slim::Music::Import->addImporter('Plugins::TIDAL::Importer', { use => 1 });

	# Track Info item
	Slim::Menu::TrackInfo->registerInfoProvider( tidalTrackInfo => (
		func  => \&trackInfoMenu,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( tidalArtistInfo => (
		func => \&artistInfoMenu
	) );

	Slim::Menu::AlbumInfo->registerInfoProvider( tidalAlbumInfo => (
		func => \&albumInfoMenu
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( tidalSearch => (
		func => \&searchMenu
	) );

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'tidal',
		menu   => 'apps',
		is_app => 1,
	);
}

sub postinitPlugin {
	my $class = shift;

	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::OnlineLibrary::Plugin') ) {
		Slim::Plugin::OnlineLibrary::Plugin->addLibraryIconProvider('tidal', '/plugins/TIDAL/html/emblem.png');

		require Slim::Plugin::OnlineLibrary::BrowseArtist;
		Slim::Plugin::OnlineLibrary::BrowseArtist->registerBrowseArtistItem( TIDAL => sub {
			my ( $client ) = @_;

			return {
				name => cstring($client, 'BROWSE_ON_SERVICE', 'TIDAL'),
				type => 'link',
				icon => $class->_pluginDataFor('icon'),
				url  => \&browseArtistMenu,
			};
		} );
	}

	if ( Slim::Utils::PluginManager->isEnabled('Plugins::LastMix::Plugin') ) {
		eval {
			require Plugins::LastMix::Services;
		};

		if (!$@) {
			main::INFOLOG && $log->info("LastMix plugin is available - let's use it!");
			require Plugins::TIDAL::LastMix;
			Plugins::LastMix::Services->registerHandler('Plugins::TIDAL::LastMix', 'lossless');
		}
	}
}

sub onlineLibraryNeedsUpdate {
	my $class = shift;
	require Plugins::TIDAL::Importer;
	return Plugins::TIDAL::Importer->needsUpdate(@_);
}

sub getLibraryStats {
	require Plugins::TIDAL::Importer;
	my $totals = Plugins::TIDAL::Importer->getLibraryStats();
	return wantarray ? ('PLUGIN_TIDAL_NAME', $totals) : $totals;
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	if ( !Plugins::TIDAL::API->getSomeUserId() ) {
		return $cb->({
			items => [{
				name => cstring($client, 'PLUGIN_TIDAL_REQUIRES_CREDENTIALS'),
				type => 'textarea',
			}]
		});
	}

	my $items = [{
		name => cstring($client, 'PLUGIN_TIDAL_FEATURES'),
		image => 'plugins/TIDAL/html/featured_MTL_svg_trophy.png',
		type => 'link',
		url => \&getFeatured,
	},{
		name => cstring($client, 'PLUGIN_TIDAL_MY_MIX'),
		image => 'plugins/TIDAL/html/mix_MTL_svg_stream.png',
		type => 'playlist',
		url => \&getMyMixes,
	},{
		name => cstring($client, 'PLAYLISTS'),
		image => 'html/images/playlists.png',
		type => 'link',
		url => \&getFavoritePlaylists,
	},{
		name => cstring($client, 'ALBUMS'),
		image => 'html/images/albums.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'albums' }],
	},{
		name => cstring($client, 'SONGS'),
		image => 'html/images/playall.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'tracks' }],
	},{
		name => cstring($client, 'ARTISTS'),
		image => 'html/images/artists.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'artists' }],
	},{
		name  => cstring($client, 'SEARCH'),
		image => 'html/images/search.png',
		type  => 'search',
		url   => sub {
			my ($client, $cb, $params) = @_;
			my $menu = searchMenu($client, {
				search => lc($params->{search})
			});
			$cb->({
				items => $menu->{items}
			});
		},
	},{
		name  => cstring($client, 'GENRES'),
		image => 'html/images/genres.png',
		type => 'link',
		url  => \&getGenres,
	},{
		name  => cstring($client, 'PLUGIN_TIDAL_MOODS'),
		image => 'plugins/TIDAL/html/moods_MTL_icon_celebration.png',
		type => 'link',
		url  => \&getMoods,
	} ];

	if ($client && scalar keys %{$prefs->get('accounts') || {}} > 1) {
		push @$items, {
			name => cstring($client, 'PLUGIN_TIDAL_SELECT_ACCOUNT'),
			image => __PACKAGE__->_pluginDataFor('icon'),
			url => \&selectAccount,
		};
	}

	$cb->({ items => $items });
}

sub browseArtistMenu {
	my ($client, $cb, $params, $args) = @_;

	my $artistId = $params->{artist_id} || $args->{artist_id};
	if ( defined($artistId) && $artistId =~ /^\d+$/ && (my $artistObj = Slim::Schema->resultset("Contributor")->find($artistId))) {
		my $renderer = sub {
			my $items = shift || { items => [] };
			$items = $items->{items};

			if ($items && ref $items eq 'ARRAY' && scalar @$items > 0) {
				$items = [ grep {
					Slim::Utils::Text::ignoreCase($_->{name} ) eq $artistObj->namesearch;
				} @$items ];
			}

			if (scalar @$items == 1 && ref $items->[0]->{items}) {
				$items = $items->[0]->{items};
			}

			$cb->( {
				items => $items
			} );
		};

		if (my ($extId) = grep /tidal:artist:(\d+)/, @{$artistObj->extIds}) {
			($args->{artistId}) = $extId =~ /tidal:artist:(\d+)/;
			return getArtist($client, $renderer, $params, $args);
		}
		else {
			$args->{search} = $artistObj->name;
			$args->{type} = 'artists';

			return search($client, $renderer, $params, $args);
		}
	}

	$cb->([{
		type  => 'text',
		title => cstring($client, 'EMPTY'),
	}]);
}

sub selectAccount {
	my ( $client, $cb ) = @_;

	my $userId = getAPIHandler($client)->userId;
	my $items = [ map {
		my $name = $_->{nickname} || $_->{username};
		$name = '* ' . $name if $_->{userId} == $userId;

		{
			name => $name,
			url => sub {
				my ($client, $cb2, $params, $args) = @_;

				$client->pluginData(api => 0);
				$prefs->client($client)->set('userId', $args->{id});

				$cb2->({ items => [{
					nextWindow => 'grandparent',
				}] });
			},
			passthrough => [{
				id => $_->{userId}
			}],
			nextWindow => 'parent'
		}
	} sort values %{ $prefs->get('accounts') || {} } ];

	$cb->({ items => $items });
}

sub albumInfoMenu {
	my ($client, $url, $album, $remoteMeta) = @_;
	$remoteMeta ||= {};

	my ($artist) = $album->artistsForRoles('ARTIST');
	($artist) ||= $album->artistsForRoles('ALBUMARTIST');

	return _objInfoMenu($client,
		$album->extid,
		($artist && $artist->name) || $remoteMeta->{artist},
		$album->title || $remoteMeta->{album},
	);
}

sub trackInfoMenu {
	my ( $client, $url, $track, $remoteMeta ) = @_;
	$remoteMeta ||= {};

	my $extid = $track->extid;
	$extid ||= $url if $url =~ /^tidal:/;

	my $artist = $track->remote ? $remoteMeta->{artist} : $track->artistName;
	my $album  = $track->remote ? $remoteMeta->{album} : $track->albumname;
	my $title  = $track->remote ? $remoteMeta->{title} : $track->title;

	my $search = cstring($client, 'SEARCH');
	my $items = [];

	my $artists = $track->remote ? $remoteMeta->{artists} : [];
	my $albumId = $track->remote ? $remoteMeta->{album_id} : undef;
	my $trackId = Plugins::TIDAL::ProtocolHandler::_getId($track->url);

	push @$items, {
		name => $album,
		line1 => $album,
		line2 => $artist,
		favorites_url => 'tidal://album:' . $albumId,
		type => 'playlist',
		url => \&getAlbum,
		image => 'html/images/albums.png',
		passthrough => [{ id => $albumId }],
	} if $albumId;

	foreach my $_artist (@$artists) {
		push @$items, _renderArtist($client, $_artist);
	}

	push @$items, {
		name => cstring($client, 'PLUGIN_TIDAL_TRACK_MIX'),
		type => 'playlist',
		url => \&getTrackRadio,
		image => 'plugins/TIDAL/html/mix_MTL_svg_stream.png',
		passthrough => [{ id => $trackId }],
	} if $trackId;

	push @$items, {
		name => "$search " . cstring($client, 'ARTIST') . " '$artist'",
		type => 'link',
		url => \&search,
		image => 'html/images/artists.png',
		passthrough => [ {
			type => 'artists',
			query => $artist,
		} ],
	} if $artist;

	push @$items, {
		name => "$search " . cstring($client, 'ALBUM') . " '$album'",
		type => 'link',
		url => \&search,
		image => 'html/images/albums.png',
		passthrough => [ {
			type => 'albums',
			query => $album,
		} ],
	} if $album;

	push @$items, {
		name => "$search " . cstring($client, 'SONG') . " '$title'",
		type => 'link',
		url => \&search,
		image => 'html/images/playall.png',
		passthrough => [ {
			type => 'tracks',
			query => $title,
		} ],
	} if $title;

	return {
		type => 'outlink',
		items => $items,
		name => cstring($client, 'PLUGIN_TIDAL_ON_TIDAL'),
	};
}

sub artistInfoMenu {
	my ($client, $url, $artist, $remoteMeta) = @_;
	$remoteMeta ||= {};

	return _objInfoMenu( $client, $artist->extid, $artist->name || $remoteMeta->{artist} );
}

sub _objInfoMenu {
	my ( $client, $extid, $artist, $album, $track, $items ) = @_;

	# TODO - use $extid!

	$items ||= [];

	push @$items, {
		name => cstring($client, 'SEARCH'),
		url  => \&searchEverything,
		passthrough => [{
			query => join(' ', $artist, $album, $track),
		}]
	};

	my $menu;
	if ( scalar @$items == 1) {
		$menu = $items->[0];
		$menu->{name} = cstring($client, 'PLUGIN_TIDAL_ON_TIDAL');
	}
	elsif (scalar @$items) {
		$menu = {
			name  => cstring($client, 'PLUGIN_TIDAL_ON_TIDAL'),
			items => $items
		};
	}

	return $menu if $menu;
}

sub searchMenu {
	my ( $client, $tags ) = @_;

	my $searchParam = { query => $tags->{search} };

	return {
		name => cstring($client, 'PLUGIN_TIDAL_NAME'),
		items => [{
			name => cstring($client, 'EVERYTHING'),
			url  => \&searchEverything,
			passthrough => [ $searchParam ],
		},{
			name => cstring($client, 'PLAYLISTS'),
			url  => \&search,
			passthrough => [ { %$searchParam, type => 'playlists'	} ],
		},{
			name => cstring($client, 'ARTISTS'),
			url  => \&search,
			passthrough => [ { %$searchParam, type => 'artists' } ],
		},{
			name => cstring($client, 'ALBUMS'),
			url  => \&search,
			passthrough => [ { %$searchParam, type => 'albums' } ],
		},{
			name => cstring($client, 'SONGS'),
			url  => \&search,
			passthrough => [ { %$searchParam, type => 'tracks' } ],
		}]
	};
}

sub getFavoritePlaylists {
	my ( $client, $cb, $args, $params ) = @_;

	Async::Util::amap(
		inputs => [
			sub {
				getFavorites($client, shift, {}, { type => 'playlists' });
			},
			sub {
				my $acb = shift;
				getAPIHandler($client)->userPlaylists(sub {
					my $items = shift;

					$items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 }) } @$items ] if $items;
					$acb->( {
						items => $items
					} );
				});
			}
		],
		action => sub {
			my ($input, $acb) = @_;
			$input->($acb);
		},
		cb => sub {
			my ($results, $error) = @_;

			my %seen;
			my $items = [ sort {
				$a->{name} cmp $b->{name}
			} grep {
				!$seen{$_->{passthrough}->[0]->{uuid}}++
			} map {
				@{$_->{items}}
			} @$results ];

			$cb->({
				items => $items
			});
		}
	);
}

sub getFavorites {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->getFavorites(sub {
		my $items = shift;

		$items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 }) } @$items ] if $items;

		$cb->( {
			items => $items
		} );
	}, $params->{type}, $args->{quantity} == 1 );
}

sub getArtist {
	my ( $client, $cb, $args, $params ) = @_;

	my $artistId = $params->{artistId};

	getAPIHandler($client)->getArtist(sub {
		my $item = _renderArtist($client, @_);
		$cb->( {
			items => [$item]
		} );
	}, $artistId);
}

sub getSimilarArtists {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->similarArtists(sub {
		my $items = shift;

		$items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 }) } @$items ] if $items;

		$cb->( {
			items => $items
		} );
	}, $params->{id});
}

sub getArtistAlbums {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->artistAlbums(sub {
		my $items = _renderAlbums(@_);
		$cb->( {
			items => $items
		} );
	}, $params->{id}, $params->{type});
}

sub getArtistTopTracks {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->artistTopTracks(sub {
		my $items = _renderTracks(@_);
		$cb->( {
			items => $items
		} );
	}, $params->{id});
}

sub getTrackRadio {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->trackRadio(sub {
		my $items = _renderTracks(@_);
		$cb->( {
			items => $items
		} );
	}, $params->{id});
}

sub getMyMixes {
	my ( $client, $cb ) = @_;

	getAPIHandler($client)->myMixes(sub {
		my $items = [ map { _renderMix($client, $_) } @{$_[0]} ];
		$cb->( {
			items => $items
		} );
	});
}

sub getMix {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->mix(sub {
		my $items = _renderTracks(@_);
		$cb->( {
			items => $items
		} );
	}, $params->{id});
}

sub getAlbum {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->albumTracks(sub {
		my $items = _renderTracks(shift);
		$cb->( {
			items => $items
		} );
	}, $params->{id});
}

sub getGenres {
	my ( $client, $callback ) = @_;

	getAPIHandler($client)->genres(sub {
		my $items = [ map { _renderItem($client, $_, { handler => \&getGenreItems }) } @{$_[0]} ];

		$callback->( { items => $items } );
	});
}

sub getGenreItems {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->genreByType(sub {
		my $items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 } ) } @{$_[0]} ];

		$cb->( {
			items => $items
		} );
	}, $params->{path}, $params->{type} );
}

sub getFeatured {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->featured(sub {
		my $items = [ map { _renderItem($client, $_, { handler => \&getFeaturedItem }) } @{$_[0]} ];

		$cb->( {
			items => $items
		} );
	});
}

sub getFeaturedItem {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->featuredItem(sub {
		my $items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 }) } @{$_[0]} ];

		$cb->( {
			items => $items
		} );
	},{
		id => $params->{path},
		type => $params->{type},
	});
}

sub getMoods {
	my ( $client, $callback, $args, $params ) = @_;
	getAPIHandler($client)->moods(sub {
		my $items = [ map {
			{
				name => $_->{name},
				type => 'link',
				url => \&getMoodPlaylists,
				image => Plugins::TIDAL::API->getImageUrl($_, 'usePlaceholder', 'mood'),
				passthrough => [ { mood => $_->{path} } ],
			};
		} @{$_[0]} ];

		$callback->( { items => $items } );
	} );
}

sub getMoodPlaylists {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->moodPlaylists(sub {
		my $items = [ map { _renderPlaylist($_) } @{$_[0]->{items}} ];

		$cb->( {
			items => $items
		} );
	}, $params->{mood} );
}

sub getPlaylist {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->playlist(sub {
		my $items = _renderTracks($_[0], 1);
		$cb->( {
			items => $items
		} );
	}, $params->{uuid} );
}

sub search {
	my ($client, $cb, $args, $params) = @_;

	$args->{search} ||= $params->{query} || $params->{search};
	$args->{type}   ||= $params->{type};

	getAPIHandler($client)->search(sub {
		my $items = shift;
		$items = [ map { _renderItem($client, $_) } @$items ] if $items;

		$cb->( {
			items => $items || []
		} );
	}, $args);

}

sub searchEverything {
	my ($client, $cb, $args, $params) = @_;

	$args->{search} ||= $params->{query};

	getAPIHandler($client)->search(sub {
		my $result = shift;
		my $items = [];

		if ($result->{topHit}) {
			$result->{topHit}->{value}->{type} = $result->{topHit}->{type};
			my $item = _renderItem($client, $result->{topHit}->{value});
			push @$items, $item if $item;
		}

		foreach my $key ("topHit", "playlists", "artists", "albums", "tracks") {
			next unless $result->{$key} && $result->{$key}->{totalNumberOfItems};

			my $entries = $key ne 'tracks' ?
						  $result->{$key}->{items} :
						  Plugins::TIDAL::API->cacheTrackMetadata($result->{$key}->{items});

			push @$items, {
				name => cstring($client, $key =~ s/tracks/songs/r),
				image => 'html/images/' . ($key ne 'tracks' ? $key : 'playall') . '.png',
				type => 'outline',
				items => [ map { _renderItem($client, $_) } @$entries ],
			}
		}

		$cb->( {
			items => $items || []
		} );
	}, $args);

}

sub _renderItem {
	my ($client, $item, $args) = @_;

	my $type = Plugins::TIDAL::API->typeOfItem($item);

	if ($type eq 'track') {
		return _renderTrack($item, $args->{addArtistToTitle});
	}
	elsif ($type eq 'album') {
		return _renderAlbum($item, $args->{addArtistToTitle});
	}
	elsif ($type eq 'artist') {
		return _renderArtist($client, $item);
	}
	elsif ($type eq 'playlist') {
		return _renderPlaylist($item);
	}
	elsif ($type eq 'category') {
		return _renderCategory($client, $item, $args->{handler});
	}
	elsif ($type eq 'mix') {
		return _renderMix($client, $item);
	}
}

sub _renderPlaylists {
	my $results = shift;

	return [ map {
		_renderPlaylist($_)
	} @{$results->{items}}];
}

sub _renderPlaylist {
	my $item = shift;

	return {
		name => $item->{title},
		line1 => $item->{title},
		line2 => join(', ', map { $_->{name} } @{$item->{promotedArtists} || []}),
		favorites_url => 'tidal://playlist:' . $item->{uuid},
		type => 'playlist',
		url => \&getPlaylist,
		image => Plugins::TIDAL::API->getImageUrl($item),
		passthrough => [ { uuid => $item->{uuid} } ],
	};
}

sub _renderAlbums {
	my ($results, $addArtistToTitle) = @_;

	return [ map {
		_renderAlbum($_, $addArtistToTitle);
	} @{$results} ];
}

sub _renderAlbum {
	my ($item, $addArtistToTitle) = @_;

	my $title = $item->{title};
	$title .= ' - ' . $item->{artist}->{name} if $addArtistToTitle;

	return {
		name => $title,
		line1 => $item->{title},
		line2 => $item->{artist}->{name},
		favorites_url => 'tidal://album:' . $item->{id},
		type => 'playlist',
		url => \&getAlbum,
		image => Plugins::TIDAL::API->getImageUrl($item, 'usePlaceholder'),
		passthrough => [{ id => $item->{id} }],
	};
}

sub _renderTracks {
	my ($tracks, $addArtistToTitle) = @_;

	return [ map {
		_renderTrack($_, $addArtistToTitle);
	} @$tracks ];
}

sub _renderTrack {
	my ($item, $addArtistToTitle) = @_;

	my $title = $item->{title};
	$title .= ' - ' . $item->{artist}->{name} if $addArtistToTitle;
	my $url = "tidal://$item->{id}." . Plugins::TIDAL::API::getFormat();

	return {
		name => $title,
		line1 => $item->{title},
		line2 => $item->{artist}->{name},
		on_select => 'play',
		url => $url,
		play => $url,
		playall => 1,
		image => $item->{cover},
	};
}

sub _renderArtists {
	my ($client, $results) = @_;

	return [ map {
		_renderArtist($client, $_);
	} @{$results->{items}} ];
}

sub _renderArtist {
	my ($client, $item) = @_;

	my $items = [{
		name => cstring($client, 'PLUGIN_TIDAL_TOP_TRACKS'),
		url => \&getArtistTopTracks,
		passthrough => [{ id => $item->{id} }],
	},{
		name => cstring($client, 'ALBUMS'),
		url => \&getArtistAlbums,
		passthrough => [{ id => $item->{id} }],
	},{
		name => cstring($client, 'PLUGIN_TIDAL_EP_SINGLES'),
		url => \&getArtistAlbums,
		passthrough => [{ id => $item->{id}, type => 'EPSANDSINGLES' }],
	},{
		name => cstring($client, 'COMPILATIONS'),
		url => \&getArtistAlbums,
		passthrough => [{ id => $item->{id}, type => 'COMPILATIONS' }],
	}];

	foreach (keys %{$item->{mixes} || {}}) {
		$log->warn($_) unless /^(?:TRACK|ARTIST)_MIX/;
		next unless /^(?:TRACK|ARTIST)_MIX/;
		push @$items, {
			name => cstring($client, "PLUGIN_TIDAL_$_"),
			favorites_url => 'tidal://mix:' . $item->{mixes}->{$_},
			type => 'playlist',
			url => \&getMix,
			passthrough => [{ id => $item->{mixes}->{$_} }],
		};
	}

	push @$items, {
		name => cstring($client, "PLUGIN_TIDAL_SIMILAR_ARTISTS"),
		url => \&getSimilarArtists,
		passthrough => [{ id => $item->{id} }],
	};

	return scalar @$items > 1
	? {
		name => $item->{name},
		type => 'outline',
		items => $items,
		image => Plugins::TIDAL::API->getImageUrl($item, 'usePlaceholder'),
	}
	: {
		%{$items->[0]},
		name => $item->{name},
		image => Plugins::TIDAL::API->getImageUrl($item, 'usePlaceholder'),
	};
}

sub _renderMix {
	my ($client, $item) = @_;

	return {
		name => $item->{title},
		line1 => $item->{title},
		line2 => join(', ', map { $_->{name} } @{$item->{artists}}),
		favorites_url => 'tidal://mix:' . $item->{id},
		type => 'playlist',
		url => \&getMix,
		image => Plugins::TIDAL::API->getImageUrl($item, 'usePlaceholder'),
		passthrough => [{ id => $item->{id} }],
	};
}

sub _renderCategory {
	my ($client, $item, $renderer) = @_;

	my $path = $item->{path};
	my $items = [];

	push @$items, {
		name => cstring($client, 'PLAYLISTS'),
		type  => 'link',
		url   => $renderer,
		passthrough => [ { path => $path, type => 'playlists' } ],
	} if $item->{hasPlaylists};

	push @$items, {
		name => cstring($client, 'ARTISTS'),
		type  => 'link',
		url   => $renderer,
		passthrough => [ { path => $path, type => 'artists' } ],
	} if $item->{hasArtists};

	push @$items, {
		name => cstring($client, 'ALBUMS'),
		type  => 'link',
		url   => $renderer,
		passthrough => [ { path => $path, type => 'albums' } ],
	} if $item->{hasAlbums};

	push @$items, {
		name => cstring($client, 'SONGS'),
		type  => 'link',
		url   => $renderer,
		passthrough => [ { path => $path, type => 'tracks' } ],
	} if $item->{hasTracks};

	return {
		name => $item->{name},
		type => 'outline',
		items => $items,
		image => Plugins::TIDAL::API->getImageUrl($item, 'usePlaceholder', 'genre'),
		passthrough => [ { path => $item->{path} } ],
	};
}

sub getAPIHandler {
	my ($client) = @_;

	my $api;

	if (ref $client) {
		$api = $client->pluginData('api');

		if ( !$api ) {
			my $userdata = Plugins::TIDAL::API->getUserdata($prefs->client($client)->get('userId'));

			# if there's no account assigned to the player, just pick one
			if ( !$userdata ) {
				my $userId = Plugins::TIDAL::API->getSomeUserId();
				$prefs->client($client)->set('userId', $userId) if $userId;
			}

			$api = $client->pluginData( api => Plugins::TIDAL::API::Async->new({
				client => $client
			}) );
		}
	}
	else {
		$api = Plugins::TIDAL::API::Async->new({
			userId => Plugins::TIDAL::API->getSomeUserId()
		});
	}

	logBacktrace("Failed to get a TIDAL API instance: $client") unless $api;

	return $api;
}

1;
