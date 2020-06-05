#!/usr/bin/perl
#
# A network configuration for a device that acts as standalone network
# controller without an upstream internet connection.
#
# Copyright (C) 2014 and later, Indie Computing Corp. All rights reserved. License: see package.
#

use strict;
use warnings;

package UBOS::Networking::NetConfigs::Standalone;

use JSON;
use UBOS::HostStatus;
use UBOS::Networking::NetConfigUtils;

my $name = 'standalone';

##
# Obtain this network configuration's name.
# return: the name
sub name {
    return $name;
}

##
# Determine whether this network configuration could currently be activated.
# This return false, if, for example, this network configuration requires two
# ethernet interfaces, but the device has only one ethernet interface attached.
# This will also return true if this configuration is currently active.
# return: 1 or 0
sub isPossible {
    return 1;
}

##
# Activate this network configuration.
# $initOnly: if true, enable services but do not start them (e.g. during ubos-install)
# $force: do not read existing configuration, initialize netconfig from scratch
sub activate {
    my $initOnly = shift;
    my $force    = shift;

    my $allNics = UBOS::HostStatus::nics();

    my $conf    = undef;
    my $error   = 0;
    my $updated = 0;

    if( $force ) {
        $conf    = {};
        $updated = 1;
    } else {
        $conf = UBOS::Networking::NetConfigUtils::readNetconfigConfFileFor( $name );
    }
    unless( $conf ) {
        $conf = {};
        $error = 1;
    }

    my $appNic = undef;
    foreach my $nic ( sort keys %$allNics ) {
        if( exists( $conf->{$nic} ) && exists( $conf->{$nic}->{appnic} ) && $conf->{$nic}->{appnic} ) {
            $appNic = $nic;
            last;
        }
    }
    unless( $appNic ) {
        foreach my $nic ( sort keys %$allNics ) {
            if(    exists( $conf->{$nic} )
                && exists( $conf->{$nic}->{address} )
                && ( !exists( $conf->{$nic}->{appnic} ) || !$conf->{$nic}->{appnic} ))
            {
                $appNic = $nic;
                last;
            }
        }
    }

    foreach my $nic ( sort keys %$allNics ) {
        unless( exists( $conf->{$nic} )) {
            my( $ip, $prefixsize ) = UBOS::Networking::NetConfigUtils::findUnusedNetwork( $conf );
            if( $ip ) {
                $conf->{$nic}->{address}    = $ip;
                $conf->{$nic}->{prefixsize} = $prefixsize;

                $conf->{$nic}->{dhcpserver} = JSON::true;
                $conf->{$nic}->{dns}        = JSON::true;
                $conf->{$nic}->{forward}    = JSON::true;
                $conf->{$nic}->{mdns}       = JSON::true;
                $conf->{$nic}->{ports}      = JSON::true;
                $conf->{$nic}->{ssh}        = JSON::true;

                $updated = 1;
            } else {
                warning( 'Cannot find unallocated network for interface', $nic );
            }
        }
    }
    if( $appNic ) {
        $conf->{$appNic}->{appnic} = JSON::true;
    }

    UBOS::Networking::NetConfigUtils::configure( $name, $conf, $initOnly );

    if( $updated && !$error ) {
        UBOS::Networking::NetConfigUtils::saveNetconfigConfFileFor( $name, $conf );
    }
}

##
# Return help text for this network configuration
# return: help text
sub help {
    return 'Be a local network controller without upstream connection to the internet.';
}

1;
