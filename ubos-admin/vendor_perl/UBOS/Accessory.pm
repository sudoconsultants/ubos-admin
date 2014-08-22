#!/usr/bin/perl
#
# Represents an Accessory for an App.
#
# This file is part of ubos-admin.
# (C) 2012-2014 Indie Computing Corp.
#
# ubos-admin is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ubos-admin is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with ubos-admin.  If not, see <http://www.gnu.org/licenses/>.
#

use strict;
use warnings;

package UBOS::Accessory;

use base qw( UBOS::Installable );
use fields;

use UBOS::Configuration;
use UBOS::Logging;
use UBOS::Utils;
use JSON;

##
# Constructor.
# $packageName: unique identifier of the package
sub new {
    my $self        = shift;
    my $packageName = shift;

    unless( ref $self ) {
        $self = fields::new( $self );
    }
    $self->SUPER::new( $packageName );

    if( $self->{config}->get( 'ubos.checkmanifest', 1 )) {
		$self->checkManifest( 'accessory' );
        $self->checkManifestAccessoryInfo();
    }
    trace( 'Created accessory', $packageName );

    return $self;
}

##
# Check validity of the manifest JSON's accessoryinfo section.
# return: 1 or exits with fatal error
sub checkManifestAccessoryInfo {
	my $self = shift;

    my $json   = $self->{json};
    
    unless( defined( $json->{accessoryinfo} )) {
        $self->myFatal( "accessoryinfo section required for accessories" );
    }
    unless( ref( $json->{accessoryinfo} ) eq 'HASH' ) {
        $self->myFatal( "accessoryinfo is not a HASH" );
    }
    unless( defined( $json->{accessoryinfo}->{appid} )) {
        $self->myFatal( "accessoryinfo section: no appid given" );
    }
    if( ref( defined( $json->{accessoryinfo}->{appid} )) || !$json->{accessoryinfo}->{appid} ) {
        $self->myFatal( "accessoryinfo section: appid must be a valid package name" );
    }
    if( defined( $json->{accessoryinfo}->{accessoryid} ) && ref( $json->{accessoryinfo}->{accessoryid} )) {
        $self->myFatal( "accessoryinfo section: accessoryid, if provided, must be a string" );
    }
    if( defined( $json->{accessoryinfo}->{accessorytype} ) && ref( $json->{accessoryinfo}->{accessorytype} )) {
        $self->myFatal( "accessoryinfo section: accessorytype, if provided, must be a string" );
    }
    
    return 1;
}

1;