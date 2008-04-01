package Slim::Plugin::AudioScrobbler::PlayerSettings;

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.audioscrobbler');
my $log   = logger('plugin.audioscrobbler');

sub name {
	return 'PLUGIN_AUDIOSCROBBLER_MODULE_NAME';
}

sub needsClient {
	return 1;
}

sub page {
	return 'plugins/AudioScrobbler/settings/player.html';
}

sub handler {
	my ($class, $client, $params) = @_;
	
	if ( $client ) {
		$params->{prefs}->{accounts}           = $prefs->get('accounts') || [];
		$params->{prefs}->{enable_scrobbling}  = $prefs->get('enable_scrobbling');
		
		$params->{prefs}->{account}            = $prefs->client($client)->get('account');
		
		if ( $params->{saveSettings} ) {
			$params->{prefs}->{account} = $params->{account};
			
			Slim::Plugin::AudioScrobbler::Plugin::changeAccount( $client, $params->{account} );
		}
	}
	
	return $class->SUPER::handler( $client, $params );
}

1;