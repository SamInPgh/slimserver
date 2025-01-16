package Slim::Menu::BrowseLibrary;

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

# Should we page through results instead of doing one huge bulk request?
use constant MAX_ALBUMS => 1500;

my $log = logger('database.info');
my $prefs = preferences('server');

# Unfortunately we can't use _generic(), as there's no CLI command to get the release types
sub _releases {
	my ($client, $callback, $args, $pt) = @_;
	my @searchTags = $pt->{'searchTags'} ? @{$pt->{'searchTags'}} : ();
	my $tags       = 'lWRSw';
	my $library_id = $args->{'library_id'} || $pt->{'library_id'};
	my $orderBy    = $args->{'orderBy'} || $pt->{'orderBy'};
	my $menuMode   = $args->{'params'}->{'menu_mode'};
	my $menuRoles  = $args->{'params'}->{'menu_roles'};
	my $search     = $args->{'search'};

	push @searchTags, "search:$search" if $search && !grep /search:/, @searchTags;
	my @originalSearchTags = @searchTags;

	# map menuRoles to name for readability
	$menuRoles = join(',', map { Slim::Schema::Contributor->roleToType($_) } split(',', $menuRoles || ''));

	Slim::Schema::Album->addReleaseTypeStrings();

	@searchTags = grep {
		$_ !~ /^role_id:/
	} grep {
		# library_id:-1 is supposed to clear/override the global library_id
		$_ && $_ !~ /(?:library_id\s*:\s*-1|remote_library)/
	} @searchTags;
	push @searchTags, "role_id:$menuRoles" if $menuRoles;

	my @artistIds = grep /artist_id:/, @searchTags;
	my $artistId;
	if (scalar @artistIds) {
		$artistIds[0] =~ /artist_id:(\d+)/;
		$artistId = $1;
	}

	my $index = $args->{index};
	my $quantity = $args->{quantity};
	my $query = 'albums';

	push @searchTags, 'tags:' . $tags if defined $tags;

	main::INFOLOG && $log->is_info && $log->info("$query ($index, $quantity): tags ->", join(', ', @searchTags));

	# get the artist's albums list to create releases sub-items etc.
	my $request = Slim::Control::Request->new( undef, [ $query, 0, MAX_ALBUMS, @searchTags ] );
	$request->execute();

	$log->error($request->getStatusText()) if $request->isStatusError();

	# compile list of release types and contributions
	my %releaseTypes;
	my %contributions;
	my %isPrimaryArtist;
	my %albumList;

	my $checkComposerGenres = !( $menuMode && $menuMode ne 'artists' && $menuRoles ) && $prefs->get('showComposerReleasesbyAlbum') == 2;
	my $allComposers = ( $menuMode && $menuMode ne 'artists' && $menuRoles ) || $prefs->get('showComposerReleasesbyAlbum') == 1;

	foreach (@{ $request->getResult('albums_loop') || [] }) {

		# map to role's name for readability
		$_->{role_ids} = join(',', map { Slim::Schema::Contributor->roleToType($_) } split(',', $_->{role_ids} || ''));
		my ($defaultRoles, $userDefinedRoles) = Slim::Schema::Contributor->splitDefaultAndCustomRoles($_->{role_ids});

		my $genreMatch = undef;
		if ( $checkComposerGenres ) {
			my $request = Slim::Control::Request->new( undef, [ 'genres', 0, MAX_ALBUMS, 'album_id:' . $_->{id} ] );
			$request->execute();

			if ($request->isStatusError()) {
				$log->error($request->getStatusText());
			}
			else {
				foreach my $genre (@{$request->getResult('genres_loop')}) {
					last if $genreMatch = Slim::Schema::Genre->isMyClassicalGenre($genre->{genre});
				}
			}
		}

		my $addToMainReleases = sub {
			$isPrimaryArtist{$_->{id}}++;
			$releaseTypes{$_->{release_type}}++;
			$albumList{$_->{release_type}} ||= [];
			push @{$albumList{$_->{release_type}}}, $_->{id};
		};

		my $addUserDefinedRoles = sub {
			foreach my $role ( split(',', $userDefinedRoles || '') ) {
				$contributions{$role} ||= [];
				push @{$contributions{$role}}, $_->{id};
			}
		};

		if ($_->{compilation}) {
			$_->{release_type} = 'COMPILATION';
			$addToMainReleases->();
			# only list default roles outside the compilations if Composer/Conductor
			if ( $defaultRoles !~ /COMPOSER|CONDUCTOR/ || $defaultRoles =~ /ARTIST|BAND/ ) {
				$addUserDefinedRoles->();
				next;
			}
		}
		# Release Types if album artist
		elsif ( $defaultRoles =~ /ALBUMARTIST/ ) {
			$addToMainReleases->();
			$addUserDefinedRoles->();
			next;
		}
		# Consider this artist the main (album) artist if there's no other, defined album artist
		elsif ( $defaultRoles =~ /ARTIST/ ) {
			my $albumArtist = Slim::Schema->first('ContributorAlbum', {
				album => $_->{id},
				role  => Slim::Schema::Contributor->typeToRole('ALBUMARTIST'),
				contributor => { '!=' => $artistId }
			});

			if (!$albumArtist) {
				$addToMainReleases->();
				$addUserDefinedRoles->();
				next;
			}
		}

		# Default roles on other releases
		foreach my $role ( grep { $_ ne 'ALBUMARTIST' } split(',', $defaultRoles || '') ) {
			# don't list as trackartist, if the artist is albumartist, too
			next if $role eq 'TRACKARTIST' && $isPrimaryArtist{$_->{id}};

			if ( $role eq 'COMPOSER' && ( $genreMatch || $allComposers ) ) {
				$role = 'COMPOSERALBUM';
			}

			$contributions{$role} ||= [];
			push @{$contributions{$role}}, $_->{id};
		}

		# User-defined roles
		$addUserDefinedRoles->();
	}

	my @items;

	@searchTags = grep { $_ !~ /^tags:/ }  @searchTags;

	my @primaryReleaseTypes = map { uc($_) } @{Slim::Schema::Album->primaryReleaseTypes};
	push @primaryReleaseTypes, 'COMPILATION';    # we handle compilations differently, it's not part of the primaryReleaseTypes
	my %primaryReleaseTypes = map { $_ => 1 } @primaryReleaseTypes;

	my @sortedReleaseTypes = (@primaryReleaseTypes, sort {
		$a cmp $b
	} grep {
		!$primaryReleaseTypes{$_};
	} keys %releaseTypes);

	foreach my $releaseType (@sortedReleaseTypes) {
		my $name = Slim::Schema::Album->releaseTypeName($releaseType, $client);

		if ($releaseTypes{uc($releaseType)}) {
			$pt->{'searchTags'} = $releaseType eq 'COMPILATION'
				? [@searchTags, 'compilation:1']
				: [@searchTags, "compilation:0", "release_type:$releaseType"];
			push @items, _createItem($name, [{%$pt}]);
		}
	}

	if (my $albumIds = delete $contributions{COMPOSERALBUM}) {
		$pt->{'searchTags'} = [@searchTags, "role_id:COMPOSER"];
		push @items, _createItem(cstring($client, 'COMPOSERALBUMS'), [{%$pt}]);
	}

	if (my $albumIds = delete $contributions{COMPOSER}) {
		push @items, {
			name        => cstring($client, 'COMPOSITIONS'),
			image       => 'html/images/playlists.png',
			type        => 'playlist',
			playlist    => \&_tracks,
			# for compositions we want to have the compositions only, not the albums
			url         => \&_tracks,
			passthrough => [ { searchTags => [@searchTags, "role_id:COMPOSER"] } ],
		};
	}

	if (my $albumIds = delete $contributions{TRACKARTIST}) {
		$pt->{'searchTags'} = [@searchTags, "role_id:TRACKARTIST"];
		push @items, _createItem(cstring($client, 'APPEARANCES'), [{%$pt}]);
	}

	foreach my $role (sort keys %contributions) {
		my $name = cstring($client, $role) if Slim::Utils::Strings::stringExists($role);
		$pt->{'searchTags'} = [@searchTags, "role_id:$role"];
		push @items, _createItem($name || ucfirst($role), [{%$pt}]);
	}

	# Add item for Classical Works if the artist has any.
	push @searchTags, "role_id:$menuRoles" if $menuRoles && $menuMode && $menuMode ne 'artists';
	push @searchTags, "genre_id:" . Slim::Schema::Genre->myClassicalGenreIds() if $checkComposerGenres;
	main::INFOLOG && $log->is_info && $log->info("works ($index, $quantity): tags ->", join(', ', @searchTags));
	my $requestRef = [ 'works', 0, MAX_ALBUMS, @searchTags ];
	my $request = Slim::Control::Request->new( $client ? $client->id() : undef, $requestRef );
	$request->execute();
	$log->error($request->getStatusText()) if $request->isStatusError();

	push @items, {
		name        => cstring($client, 'WORKS_CLASSICAL'),
		image       => 'html/images/works.png',
		type        => 'playlist',
		playlist    => \&_tracks,
		url         => \&_works,
		passthrough => [ { searchTags => [@searchTags, "work_id:-1", "wantMetadata:1", "wantIndex:1"] } ],
	} if ( $request->getResult('count') > 1 || ( scalar @items && $request->getResult('count') ) );

	# restore original search tags
	$pt->{'searchTags'} = [@originalSearchTags];

	# if there's only one category, display it directly
	if (scalar @items == 1 && (my $handler = $items[0]->{url})) {
		$handler->($client, $callback, $args, $pt);
	}
	# we didn't find anything
	elsif (!scalar @items) {
		_albums($client, $callback, $args, $pt);
	}
	# navigate categories if there's more than one
	else {
		# add extra items
		if ( $artistId ) {
			foreach ( grep { $_ } map { $_->($artistId) } @{getExtraItems('artist')} ) {
				push @items, $_;
			}
		}

		# add "All" item
		push @items, {
			name        => cstring($client, 'ALL_RELEASES'),
			image       => 'html/images/albums.png',
			type        => 'playlist',
			playlist    => \&_tracks,
			url         => \&_albums,
			passthrough => [ $pt ],
		};

		my $result = $quantity == 1 ? {
			items => [ $items[$index] ],
			total => $quantity,
		} : {
			items => \@items,
			total => scalar @items,
		};

		$result->{offset} = $index;
		$result->{sorted} = 1;

		$callback->($result);
	}
}

sub _createItem {
	my ($name, $pt) = @_;

	return {
		name        => $name,
		image       => 'html/images/albums.png',
		type        => 'playlist',
		playlist    => \&_tracks,
		url         => \&_albums,
		passthrough => $pt,
	};
}

1;
