#!/usr/bin/perl
#
# Encapsulates data transfer options, and their management in a defaults
# file.
#
# Copyright (C) 2014 and later, Indie Computing Corp. All rights reserved. License: see package.
#

use strict;
use warnings;

package UBOS::DataTransferConfiguration;

use fields qw( config configChanged configFirstTime configFile noStoreConfig );

use UBOS::Logging;
use UBOS::Utils;

##
# Constructor.
# $defaultConfigFile: the name of the default configuration file
# $userConfigFile: name of the configuration file provided by the user
# $noStore: if true, do not read or write any configuration file
sub new {
    my $self              = shift;
    my $defaultConfigFile = shift;
    my $userConfigFile    = shift;
    my $noStoreConfig     = shift;

    my $config;
    my $configFile;
    my $configFirstTime = 1;
    my $configChanged   = 0;

    if( $userConfigFile ) {
        unless( -e $userConfigFile ) {
            fatal( 'Specified data transfer config file does not exist:', $userConfigFile );
        }
        $configFile = $userConfigFile;
    } else {
        $configFile = $defaultConfigFile;
    }

    if( !$noStoreConfig && -e $configFile ) {
        $config = UBOS::Utils::readJsonFromFile( $configFile );
        unless( $config ) {
            fatal( 'Failed to parse data transfer config file:', $configFile );
        }
        $configFirstTime = 0;
    } else {
        $config = {}; # by default we have nothing
    }

    unless( ref( $self )) {
        $self = fields::new( $self );
    }

    $self->{config}          = $config;
    $self->{configChanged}   = $configChanged;
    $self->{configFirstTime} = $configFirstTime;
    $self->{configFile}      = $configFile;
    $self->{noStoreConfig}   = $noStoreConfig;

    return $self;
}

##
# Obtain a configuration value
# $protocol: name of the protocol, for finding the right section
# $authority: username '@' hostname, or just hostname, where this applies
# $key: name of the setting within the authority section
# $default: if no such value is known, return this value
# return the value
sub getValue {
    my $self      = shift;
    my $protocol  = shift;
    my $authority = shift;
    my $key       = shift;
    my $default   = shift;

    my $config = $self->{config};
    my $value  = $default;

    if(    exists( $config->{$protocol} )
        && exists( $config->{$protocol}->{$authority} )
        && exists( $config->{$protocol}->{$authority}->{$key} ))
    {
        $value = $config->{$protocol}->{$authority}->{$key};
    }
    return $value;
}

##
# Set a new configuration value
# $protocol: name of the protocol, for finding the right section
# $authority: username '@' hostname, or just hostname, where this applies
# $key: name of the setting within the authority section
# $value: the new value
# return true if the setting was changed
sub setValue {
    my $self      = shift;
    my $protocol  = shift;
    my $authority = shift;
    my $key       = shift;
    my $value     = shift;

    my $config = $self->{config};

    if(    exists( $config->{$protocol} )
        && exists( $config->{$protocol}->{$authority} )
        && exists( $config->{$protocol}->{$authority}->{$key} ))
    {
        my $existingValue = $config->{$protocol}->{$authority}->{$key};

        unless( _diff( $value, $existingValue )) {
            return 0;
        }
    }
    if( defined( $value )) {
        $config->{$protocol}->{$authority}->{$key} = $value;
        $self->{configChanged} = 1;
    }
    return 1;
}

##
# Unset a value
# $protocol: name of the protocol, for finding the right section
# $authority: username '@' hostname, or just hostname, where this applies
# $key: name of the setting within the authority section
sub removeValue {
    my $self      = shift;
    my $protocol  = shift;
    my $authority = shift;
    my $key       = shift;

    my $config = $self->{config};
    my $value  = undef;

    if(    exists( $config->{$protocol} )
        && exists( $config->{$protocol}->{$authority} ))
    {
        delete $config->{$protocol}->{$authority}->{$key};
    }
}

##
# Save the new values, if needed
# return: true if an actual save occurred
sub saveIfNeeded {
    my $self = shift;

    if( $self->{noStoreConfig} ) {
        return 0;
    }
    if( $self->{configChanged} ) {
        if( UBOS::Utils::writeJsonToFile( $self->{configFile}, $self->{config}, 0600 )) {
            if( $self->{configFirstTime} ) {
                info( 'Data transfer config saved as defaults for next time.' );
            } else {
                info( 'Data transfer config changed. Defaults were updated.' );
            }
        } else {
            warning( 'Failed to save data transfer config to:', $self->{configFile} );
        }

        return 1;
    }
    return 0;
}

##
# Helper to diff two (potentially type-differing) values.
# $a: first value
# $b: second value
# return: 0 if no difference, 1 if there is
sub _diff {
    my $a = shift;
    my $b = shift;

    if( !defined( $a )) {
        return defined( $b );
    }

    if( ref( $a ) eq 'ARRAY' ) {
        if( ref( $b ) eq 'ARRAY' ) {
            if( @$a != @$b ) {
                return 1;
            }
            for( my $i=0 ; $i<@$a ; ++$i ) {
                if( _diff( $a->[$i], $b->[$i] )) {
                    return 1;
                }
            }
            return 0;

        } else {
            return 1;
        }
    }

    if( ref( $a ) eq 'HASH' ) {
        if( ref( $b ) eq 'HASH' ) {
            if( keys %$a != keys %$b ) {
                return 1;
            }
            foreach my $k ( sort keys %$a ) {
                if( exists( $b->{$k} )) {
                    if( _diff( $a->{$k}, $b->{$k} )) {
                        return 1;
                    }
                } else {
                    return 1;
                }
            }
            return 0;

        } else {
            return 1;
        }
    }

    if( defined( $b )) {
        return $a ne $b;
    }
    return 1;
}

1;

