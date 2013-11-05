package Plugins::MusicArtistInfo::AlbumInfo;

use strict;

use Slim::Menu::AlbumInfo;
use Slim::Menu::TrackInfo;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;

use Plugins::MusicArtistInfo::ArtistInfo;
use Plugins::MusicArtistInfo::AllMusic;
use Plugins::MusicArtistInfo::Common;
use Plugins::MusicArtistInfo::LFM;

*_cleanupAlbumName = \&Plugins::MusicArtistInfo::Common::cleanupAlbumName;

use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);

my $log = logger('plugin.musicartistinfo');

sub init {
	Slim::Menu::AlbumInfo->registerInfoProvider( moremusicinfo => (
		func => \&_objInfoHandler,
		after => 'moreartistinfo',
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( moremusicinfo => (
		func => \&_objInfoHandler,
		after => 'moreartistinfo',
	) );
	
	if (CAN_IMAGEPROXY) {
		require Plugins::MusicArtistInfo::Discogs;
	}
	
	Plugins::MusicArtistInfo::LFM->aid($_[1]);
}

sub getAlbumMenu {
	my ($client, $cb, $params, $args) = @_;
	
	$params ||= {};
	$args   ||= {};
	
	my $args2 = $params->{'album'} 
			|| _getAlbumFromAlbumId($params->{album_id}) 
			|| _getAlbumFromSongURL($client) unless $args->{url} || $args->{id};
			
	$args->{album}  ||= $args2->{album};
	$args->{artist} ||= $args2->{artist};
	$args->{album}  = _cleanupAlbumName($args->{album});
	
	main::DEBUGLOG && $log->debug("Getting album menu for " . $args->{album} . ' by ' . $args->{artist});
	
	my $pt = [$args];

	my $items = [ {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMDETAILS'),
		type => 'link',
		url  => \&getAlbumInfo,
		passthrough => $pt,
	},{
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMCREDITS'),
		type => 'link',
		url  => \&getAlbumCredits,
		passthrough => $pt,
	} ];
	
	if ( !$params->{isButton} ) {
		unshift @$items, {
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMREVIEW'),
			type => 'link',
			url  => \&getAlbumReview,
			passthrough => $pt,
		};
		
		push @$items, {
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUM_COVER'),
			# we don't want slideshow mode on controllers, but web UI only
			type => ($client && $client->controllerUA || '') =~ /squeezeplay/i ? 'link' : 'slideshow',
			url  => \&getAlbumCovers,
			passthrough => $pt,
		};
	}
	
	if ($cb) {
		$cb->({
			items => $items,
		});
	}
	else {
		return $items;
	}
}

sub getAlbumReview {
	my ($client, $cb, $params, $args) = @_;

	Plugins::MusicArtistInfo::AllMusic->getAlbumReview($client,
		sub {
			my $review = shift;
			my $items = [];
			
			if ($review->{error}) {
				$items = [{
					name => $review->{error},
					type => 'text'
				}]
			}
			elsif ($review->{review}) {
				my $content = '';
				if ( $params->{isWeb} ) {
					$content = '<h4>' . $review->{author} . '</h4>' if $review->{author};
					$content .= '<div><img src="' . $review->{image} . '"></div>' if $review->{image};
					$content .= $review->{review};
				}
				else {
					$content = $review->{author} . '\n\n' if $review->{author};
					$content .= $review->{reviewText};
				}
				
				# TODO - textarea not supported in button mode!
				push @$items, {
					name => $content,
					type => 'textarea',
				};
			}
			
			$cb->($items);
		},
		$args,
	);
}

sub getAlbumCovers {
	my ($client, $cb, $params, $args) = @_;

	my $results = {};

	my $getAlbumCoversCb = sub {
		my $covers = shift;
		
		# only continue once we have results from all services.
		return unless $covers->{lfm} && $covers->{allmusic} && $covers->{discogs};
		
		my $items = [];
		
		if ( $covers->{lfm}->{images} || $covers->{allmusic}->{images} || $covers->{discogs}->{images} ) {
			my @covers;
			push @covers, @{$covers->{allmusic}->{images}} if ref $covers->{allmusic}->{images} eq 'ARRAY';
			push @covers, @{$covers->{lfm}->{images}} if ref $covers->{lfm}->{images} eq 'ARRAY';
			push @covers, @{$covers->{discogs}->{images}} if ref $covers->{discogs}->{images} eq 'ARRAY';

			foreach my $cover (@covers) {
				my $size = $cover->{width} || '';
				if ( $cover->{height} ) {
					$size .= ($size ? 'x' : '') . $cover->{height};
				}
				
				my ($type) = $cover->{url} =~ /\.(gif|png|jpe?g)(?:\?.+|)$/i;
				$type = uc($type || '');
				
				if ($size) {
					$size .= 'px' if $size =~ /\d+$/;
					$size .= ", $type" if $type;
					$size = " ($size)";
				}
				elsif ($type) {
					$size = " ($type)";
				}
				
				push @$items, {
					type  => 'text',
					name  => $cover->{author} . $size,
					image => $cover->{url},
					jive  => {
						showBigArtwork => 1,
						actions => {
							do => {
								cmd => [ 'artwork', $cover->{url} ]
							},
						},
					}
				};
			}
		}
		
		if ( !scalar @$items ) {
			$items = [{
				name => $covers->{lfm}->{error} || $covers->{allmusic}->{error} || $covers->{discogs}->{error}  || cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'),
				type => 'text'
			}];
		}
		
		$cb->($items);
	};

	# there's a rate limiting issue on discogs.com: don't use it without imageproxy, as this seems to work around the limitation...
	if (CAN_IMAGEPROXY) {
		Plugins::MusicArtistInfo::Discogs->getAlbumCovers($client, sub {
			$results->{discogs} = shift;
			$getAlbumCoversCb->($results);
		}, $args);
	}
	else {
		$results->{discogs} = {};
	}

	Plugins::MusicArtistInfo::AllMusic->getAlbumCovers($client, sub {
		$results->{allmusic} = shift;
		$getAlbumCoversCb->($results);
	}, $args);
	
	Plugins::MusicArtistInfo::LFM->getAlbumCovers($client, sub {
		$results->{lfm} = shift;
		$getAlbumCoversCb->($results);
	}, $args);
}

sub getAlbumInfo {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::MusicArtistInfo::AllMusic->getAlbumDetails($client,
		sub {
			my $details = shift;
			my $items = [];

			if ($details->{error}) {
				$items = [{
					name => $details->{error},
					type => 'text'
				}]
			}
			elsif ( $details->{items} ) {
				my $colon = cstring($client, 'COLON');
				
				$items = [ map {
					my ($k, $v) = each %{$_};
					
					ref $v eq 'ARRAY' ? {
						name  => $k,
						type  => 'outline',
						items => [ map {
							{
								name => $_,
								type => 'text'
							}
						} @$v ],
					}:{
						name => "$k$colon $v",
						type => 'text'
					}
				} @{$details->{items}} ];
				
				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($items));
			}
									
			$cb->($items);
		},
		$args,
	);
}

sub getAlbumCredits {
	my ($client, $cb, $params, $args) = @_;
	
	warn Data::Dump::dump($args);

	Plugins::MusicArtistInfo::AllMusic->getAlbumCredits($client,
		sub {
			my $credits = shift || {};
			
			my $items = [];
			
			if ($credits->{error}) {
				$items = [{
					name => $credits->{error},
					type => 'text'
				}]
			}
			elsif ( $credits->{items} ) {
				$items = [ map {
					my $name = $_->{name};
					
					if ($_->{credit}) {
						$name .= cstring($client, 'COLON') . ' ' . $_->{credit};
					}

					my $item = {
						name => $name,
						type => 'text',
					};
					
					if ($_->{url} || $_->{id}) {
						$item->{url} = \&Plugins::MusicArtistInfo::ArtistInfo::getArtistMenu;
						$item->{passthrough} = [{ 
							url => $_->{url},
							id  => $_->{id},
						}];
						$item->{type} = 'link';
					}
					
					$item;
				} @{$credits->{items}} ] if $credits->{items};
				
				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($items));
			}
			
			$cb->($items);
		},
		$args,
	);
}

sub _objInfoHandler {
	my ( $client, $url, $obj, $remoteMeta ) = @_;

	my ($album, $artist);
	
	if ( $obj && blessed $obj ) {
		if ($obj->isa('Slim::Schema::Track')) {
			$album  = $obj->albumname || $remoteMeta->{album};
			$artist = $obj->artistName || $remoteMeta->{artist};
		}
		elsif ($obj->isa('Slim::Schema::Album')) {
			$album  = $obj->name || $remoteMeta->{name};
			$artist = $obj->contributor->name || $remoteMeta->{artist};
		}
		else {
			#warn Data::Dump::dump($obj);
		}
	}

	$album = _getAlbumFromSongURL($client, $url) if !$album && $url;

	return unless $album;

	my $args = {
		album => {
			album  => $album,
			artist => $artist,
		}
	};

	my $items = getAlbumMenu($client, undef, $args);
	
	return {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMINFO'),
		type => 'outline',
		items => $items,
		passthrough => [ $args ],
	};	
}

sub _getAlbumFromAlbumId {
	my $albumId = shift;

	if ($albumId) {
		my $album = Slim::Schema->resultset("Album")->find($albumId);

		if ($album) {
			main::INFOLOG && $log->info('Got Album/Artist from album ID: ' . $album->title . ' - ' . $album-contributor->name);
			
			return {
				artist => $album->contributor->name,
				album  => _cleanupAlbumName($album->title),
			};
		}
	}
}

sub _getAlbumFromSongURL {
	my $client = shift;
	
	return unless $client;

	my %album;

	if (my $url = Slim::Player::Playlist::song($client)) {
		$url = $url->url;

		my $track = Slim::Schema->objectForUrl($url);

		my ($artist, $album);
		$artist = $track->artist->name if (defined $track->artist);
		$album  = $track->album->title if (defined $track->album);

		# We didn't get an artist - maybe it is some music service?
		if ( !($album && $artist) && $track->remote() ) {
			my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);

			if ( $handler && $handler->can('getMetadataFor') ) {
				my $remoteMeta = $handler->getMetadataFor($client, $url);
				$album  ||= $remoteMeta->{album};
				$artist ||= $remoteMeta->{artist};
			}

			main::INFOLOG && $log->info("Got Album/artist from remote track: $album - $artist");
		}
		elsif (main::INFOLOG) {
			main::INFOLOG && $log->info("Got Album/artist current track: $album - $artist");
		}

		if ($album && $artist) {
			return {
				artist => $artist,
				album  => _cleanupAlbumName($album),
			};
		}
	}
}

1;