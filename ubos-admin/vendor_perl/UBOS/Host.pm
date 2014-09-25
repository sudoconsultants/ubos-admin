#!/usr/bin/perl
#
# Represents the local host.
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

package UBOS::Host;

use UBOS::Apache2;
use UBOS::Configuration;
use UBOS::Logging;
use UBOS::Roles::apache2;
use UBOS::Roles::mysql;
use UBOS::Roles::tomcat7;
use UBOS::Site;
use UBOS::Utils qw( readJsonFromFile myexec );
use Sys::Hostname;

my $SITES_DIR        = '/var/lib/ubos/sites';
my $HOST_CONF_FILE   = '/etc/ubos/config.json';
my $hostConf         = undef;
my $now              = time();
my @_rolesOnHostInSequence = (); # allocated as needed
my %_rolesOnHost           = (); # allocated as needed

my @essentialServices = qw( cronie ntpd );

##
# Obtain the host Configuration object.
# return: Configuration object
sub config {
    unless( $hostConf ) {
        my $raw = readJsonFromFile( $HOST_CONF_FILE );

        $raw->{hostname}        = hostname;
        $raw->{now}->{unixtime} = $now;
        $raw->{now}->{tstamp}   = UBOS::Utils::time2string( $now );

        $hostConf = new UBOS::Configuration( 'Host', $raw );
    }
}

##
# Determine all Sites currently installed on this host.
# return: hash of siteId to Site
sub sites {
    my %ret = ();
    foreach my $f ( <"$SITES_DIR/*.json"> ) {
        my $siteJson = readJsonFromFile( $f );
        my $site     = new UBOS::Site( $siteJson );
        $ret{$site->siteId()} = $site;
    }
    return \%ret;
}

##
# Find a particular Site currently installed on this host.
# $siteId: the Site identifier
# return: the Site
sub findSiteById {
    my $siteId = shift;

    my $jsonFile = "$SITES_DIR/$siteId.json";
    if( -r $jsonFile ) {
        my $siteJson = readJsonFromFile( $jsonFile );
        my $site     = new UBOS::Site( $siteJson );

        return $site;
    }
    return undef;
}

##
# Find a particular Site currently installed on this host by a complete or
# partial identifier.
# $id: the complete or partial Site identifier
# return: the Site
sub findSiteByPartialId {
	my $id = shift;

    my @candidates;
    my $siteFile;
    if( $id =~ m!^(.*)\.\.\.$! ) {
        my $partial = $1;
        my @candidates = <"$SITES_DIR/$partial?*.json">; # needs to have at least one more char
        if( @candidates == 1 ) {
            $siteFile = $candidates[0];

        } elsif( @candidates ) {
	        $@ = "There is more than one site whose siteid starts with $partial: " . join( " vs ", map { m!/(s[0-9a-fA-F]{40})\.json! } @candidates ) . '.';
            return undef;

        } else {
            $@ = "No site found whose siteid starts with $partial.";
            return undef;
        }
	
    } else {
        if( -e "$SITES_DIR/$id.json" ) {
            $siteFile = "$SITES_DIR/$id.json";
        } else {
            $@ = "No site found with siteid $id.";
            return undef;
        }
    }

    my $siteJson = readJsonFromFile( $siteFile );
    my $site     = new UBOS::Site( $siteJson );

    return $site;
}

##
# Find a particular Site currently installed on this host by its hostname
# $host: hostname
# return: the Site
sub findSiteByHostname {
    my $host = shift;
    
    my $sites = UBOS::Host::sites();

    while( my( $siteId, $site ) = each %$sites ) {
        if( $site->hostName eq $host ) {
            return $site;
        }
    }
    return undef;
}

##
# A site has been deployed.
# $site: the newly deployed or updated site
sub siteDeployed {
    my $site = shift;

    my $siteId   = $site->siteId;
    my $siteJson = $site->siteJson;

    debug( 'Host::siteDeployed', $siteId );

    UBOS::Utils::writeJsonToFile( "$SITES_DIR/$siteId.json", $siteJson );
}

##
# A site has been undeployed.
# $site: the undeployed site
sub siteUndeployed {
    my $site = shift;

    my $siteId = $site->siteId;

    debug( 'Host::siteUndeployed', $siteId );

    UBOS::Utils::deleteFile( "$SITES_DIR/$siteId.json" );
}

##
# Determine the roles that this host has chosen to use and support. For now, this is
# fixed.
# return: hash of role name to Role
sub rolesOnHost {
    unless( %_rolesOnHost ) {
        my @inSequence = rolesOnHostInSequence();
        foreach my $role ( @inSequence ) {
            $_rolesOnHost{ $role->name } = $role;
        }
    }
    return \%_rolesOnHost;
}

##
# Determine the roles that this host has chosen to use and support, in sequence
# of installation: databases before middleware before web server.
# return: the Roles, in sequence

sub rolesOnHostInSequence {
    unless( @_rolesOnHostInSequence ) {
        @_rolesOnHostInSequence = (
                new UBOS::Roles::mysql,
                # new UBOS::Roles::postgresql,
                # new UBOS::Roles::mongo,
                new UBOS::Roles::tomcat7,
                new UBOS::Roles::apache2 );
    }
    return @_rolesOnHostInSequence;
}

##
# Execute the named triggers
# $triggers: array of trigger names
sub executeTriggers {
    my $triggers = shift;

    my @triggerList;
    if( ref( $triggers ) eq 'HASH' ) {
        @triggerList = keys %$triggers;
    } elsif( ref( $triggers ) eq 'ARRAY' ) {
        @triggerList = @$triggers;
    } else {
        fatal( 'Unexpected type:', $triggers );
    }

    debug( 'Host::executeTriggers:', @triggerList );

    foreach my $trigger ( @triggerList ) {
        if( 'httpd-reload' eq $trigger ) {
            UBOS::Apache2::reload();
        } elsif( 'httpd-restart' eq $trigger ) {
            UBOS::Apache2::restart();
        } elsif( 'tomcat7-reload' eq $trigger ) {
            UBOS::Tomcat7::reload();
        } elsif( 'tomcat7-restart' eq $trigger ) {
            UBOS::Tomcat7::restart();
        } else {
            warning( 'Unknown trigger:', $trigger );
        }
    }
}

##
# Update all the code currently installed on this host.
sub updateCode {

    my $cmd = 'pacman -Syu --noconfirm';
    unless( UBOS::Logging::isDebugActive() ) {
        $cmd .= ' > /dev/null';
    }
    myexec( $cmd );
}

##
# Clean package cache
sub purgeCache {

    my $cmd = 'pacman -Sc --noconfirm';
    unless( UBOS::Logging::isDebugActive() ) {
        $cmd .= ' > /dev/null';
    }
    myexec( $cmd );
}

##
# Install the named packages.
# $packages: List of packages
# return: number of actually installed packages
sub installPackages {
    my $packages = shift;

    my @packageList;
    if( ref( $packages ) eq 'HASH' ) {
        @packageList = keys %$packages;
    } elsif( ref( $packages ) eq 'ARRAY' ) {
        @packageList = @$packages;
    } elsif( ref( $packages )) {
        fatal( 'Unexpected type:', $packages );
    } else {
        @packageList = ( $packages );
    }

    # only install what isn't installed yet
    my @filteredPackageList = grep { myexec( "pacman -Q $_ > /dev/null 2>&1" ) } @packageList;

    if( @filteredPackageList ) {
        my $err;
        my $cmd = 'sudo pacman -S --noconfirm ' . join( ' ', @filteredPackageList );
        unless( UBOS::Logging::isDebugActive() ) {
            $cmd .= ' > /dev/null';
        }

        if( myexec( $cmd, undef, undef, \$err )) {
            fatal( 'Failed to install package(s). Pacman says:', $err );
        }
    }
    return 0 + @filteredPackageList;
}

##
# Install the provided package files
# $packageFiles: List of package files
# return: number of installed packages
sub installPackageFiles {
    my $packageFiles = shift;

    my $err;
    my $cmd = 'sudo pacman -U --noconfirm ' . join( ' ', @$packageFiles );
        unless( UBOS::Logging::isDebugActive() ) {
            $cmd .= ' > /dev/null';
        }

    if( myexec( $cmd, undef, undef, \$err )) {
        error( 'Failed to install package file(s). Pacman says:', $err );
        return 0;
    }
    return 0 + ( @$packageFiles );
}

##
# Prevent interruptions of this script
sub preventInterruptions {
    $SIG{'HUP'}  = 'IGNORE';
    $SIG{'INT'}  = 'IGNORE';
    $SIG{'QUIT'} = 'IGNORE';
}

my $dbTypes           = {}; # cache
my $dbDriverInstances = {}; # cache: maps short-name to host:port to instance of driver

##
# Return which database types are available.
# return: hash of short-name to package name
sub _findDatabases {
    unless( %$dbTypes ) {
        my $full = UBOS::Utils::findPerlModuleNamesInPackage( 'UBOS::Databases' );
        while( my( $fileName, $packageName ) = each %$full ) {
            if( $packageName =~ m!::([A-Za-z0-9_]+)Driver$! ) {
                my $shortName = $1;
                $shortName =~ s!([A-Z])!lc($1)!ge;
                $dbTypes->{$shortName} = $packageName;
            }
        }
    }
    return $dbTypes;
}

##
# Return an instance of a database driver for the given short-name
# $shortName: short name of the database type, e.g. 'mysql'
# $dbHost: host on which the database runs
# $dbPort: port on which the database can be reached on that port
# return: database driver, e.g. an instance of UBOS::Databases::MySqlDriver
sub obtainDbDriver {
    my $shortName = shift;
    my $dbHost    = shift;
    my $dbPort    = shift || 'default';
    
    my $ret = $dbDriverInstances->{$shortName}->{"$dbHost:$dbPort"};
    unless( $ret ) {
        my $dbs = _findDatabases();
        my $db  = $dbs->{$shortName};
        if( $db ) {
            $ret = UBOS::Utils::invokeMethod( $db . '::new', $db, $dbHost, $dbPort );
            
            if( $dbPort eq 'default' ) {
                $dbDriverInstances->{$shortName}->{"$dbHost:default"} = $ret;
                $dbPort = $ret->defaultPort();
            }
            $dbDriverInstances->{$shortName}->{"$dbHost:$dbPort"} = $ret;
        }
    }
    return $ret;
}

##
# Ensure that pacman has been initialized. This may generate a key pair, which
# means it cannot be pre-installed; it also may take some time, depending on
# how much entropy is available.
sub ensurePacmanInit {
    UBOS::Utils::myexec( "pacman-key --init" );
    UBOS::Utils::myexec( "pacman-key --populate archlinux" );
}

1;
