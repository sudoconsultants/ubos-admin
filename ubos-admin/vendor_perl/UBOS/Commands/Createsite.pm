#!/usr/bin/perl
#
# Command that asks the users about the site they want to create, and
# then deploys the site.
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

package UBOS::Commands::Createsite;

use Cwd;
use File::Basename;
use Getopt::Long qw( GetOptionsFromArray );
use UBOS::Host;
use UBOS::Installable;
use UBOS::Logging;
use UBOS::UpdateBackup;
use UBOS::Utils;

##
# Execute this command.
# return: desired exit code
sub run {
    my @args = @_;

    if ( $< != 0 ) {
        fatal( "This command must be run as root" ); 
    }

    my $verbose       = 0;
    my $logConfigFile = undef;
    my $dryRun;

    my $parseOk = GetOptionsFromArray(
            \@args,
            'verbose+'    => \$verbose,
            'logConfig=s' => \$logConfigFile,
            'dry-run|n'   => \$dryRun );

    UBOS::Logging::initialize( 'ubos-admin', 'createsite', $verbose, $logConfigFile );

    if( !$parseOk || @args || ( $verbose && $logConfigFile )) {
        fatal( 'Invalid invocation: createsite', @_, '(add --help for help)' );
    }

    my $appId = ask( "App to run: ", '^[-._a-z0-9]+$' );
    UBOS::Host::installPackages( $appId );

    my $app = new UBOS::App( $appId );

    my $oldSites     = UBOS::Host::sites();
    my $existingSite = undef;
    my $hostname     = undef;
    outer: while( 1 ) {
        $hostname = ask( "Hostname for app: ", '^[a-z0-9]([-_a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-_a-z0-9]*[a-z0-9])?)*$' );

        foreach my $oldSite ( values %$oldSites ) {
            if( $oldSite->hostName eq $hostname ) {
                print "There is already a site with hostname $hostname.\n";
                my $yn = ask( "Add app $appId to $hostname? (y/n) " );
                if( $yn !~ m!^y(es)?$!i ) {
                    next outer;
                }
                $existingSite = $oldSite;
            }
        }
        last;
    }

    my $defaultContext = $app->defaultContext;
    my $context        = undef;
    if( $defaultContext ) {
        print "App $appId suggests context path " . $app->defaultContext . "\n";
        my $existingAppConfig;
        if( $existingSite ) {
            $existingAppConfig = $existingSite->appConfigAtContext( $defaultContext );
        }
        if( $existingAppConfig ) {
            print 'But: app ' . $existingAppConfig->app->packageName . " already runs at $defaultContext. You need to choose something different.\n";
        }
        while( 1 ) {
            $context = ask( 'Enter context path: ' );

            if( UBOS::AppConfiguration::isValidContext( $context )) {
                if( $existingSite ) {
                    my $error = $existingSite->mayContextBeAdded( $context );
                    if( $error ) {
                        print $error . " You need to choose something different.\n";
                    } else {
						last;
					}
                } else {
					last;
				}
            } else {
                print "Invalid context path. A valid context path is either empty or starts with a slash; no spaces\n";
            }
        }
    }

    my $accessories = ask( "Any accessories for $appId? Enter list: " );
    $accessories =~ s!^\s+!!;
    $accessories =~ s!\s+$!!;
    my @accs = ();
    foreach my $accId ( split( /\s+,?\s*/, $accessories )) {
        UBOS::Host::installPackages( $accId );
        my $acc = new UBOS::Accessory( $accId );

        push @accs, $acc;
    }

    my $custPointValues = {};
    foreach my $installable ( $app, @accs ) {
        my $custPoints = $installable->customizationPoints;
        if( $custPoints ) {
            my $knownCustomizationPointTypes = $UBOS::Installable::knownCustomizationPointTypes;

            while( my( $custPointName, $custPointDef ) = each( %$custPoints )) {
                # only ask for required values
                unless( $custPointDef->{required} ) {
                    next;
                }
                my $value = ask( (( $installable == $app ) ? 'App' : 'Accessory' ) . ' ' . $installable->packageName . " requires a value for $custPointName: " );

                my $custPointValidation = $knownCustomizationPointTypes->{ $custPointDef->{type}};
                unless( $custPointValidation->{valuecheck}->( $value )) {
                    fatal(  $custPointValidation->{valuecheckerror} );
                }
                $custPointValues->{$installable->packageName}->{$custPointName} = $value;
            }
        }
    }

    my $newSiteJsonString;
    
    my $siteId;
    my $appConfigId;
    my $adminUserId;
    my $adminUserName;
    my $adminCredential;
    my $adminEmail;

    if( $existingSite ) {
        my $json = $existingSite->{json};

        $siteId      = $json->{siteid};
        $appConfigId = 'a' . UBOS::Utils::randomHex( 40 );

        $adminUserId     = $json->{admin}->{userid};
        $adminUserName   = $json->{admin}->{username};
        $adminCredential = $json->{admin}->{credential};
        $adminEmail      = $json->{admin}->{email};

    } else {
        $siteId      = 's' . UBOS::Utils::randomHex( 40 );
        $appConfigId = 'a' . UBOS::Utils::randomHex( 40 );

        $adminUserId     = ask( 'Site admin user id (e.g. admin): ', '^[a-z0-9]+$' );
        $adminUserName   = ask( 'Site admin user name (e.g. John Doe): ' );
        do {
            $adminCredential = ask( 'Site admin user password (e.g. s3cr3t): ', '^\S+$', undef, 1 );
        } while( $adminCredential =~ m!s3cr3t!i );
        $adminEmail      = ask( 'Site admin user e-mail (e.g. foo@bar.com): ', '^[a-z0-9._%+-]+@[a-z0-9.-]*[a-z]$' );
    }

    $newSiteJsonString = <<JSON;
{
    "siteid" : "$siteId",
    "hostname" : "$hostname",

JSON
    if( $existingSite && $existingSite->{json}->{ssl} ) {
        $newSiteJsonString .= UBOS::Utils::writeJsonToString( $existingSite->{json}->{ssl} );
    }
    $newSiteJsonString .= <<JSON;
    "admin" : {
        "userid" : "$adminUserId",
        "username" : "$adminUserName",
        "credential" : "$adminCredential",
        "email" : "$adminEmail"
    },

    "appconfigs" : [
JSON
    if( $existingSite ) {
        foreach my $appConfig ( @{$existingSite->appConfigs} ) {
            my $toAdd = UBOS::Utils::writeJsonToString( $appConfig->{json} );
            $toAdd =~ s!\s+$!!;
            $toAdd =~ s!^!        !mg;
            $newSiteJsonString .= "\n" . $toAdd;
        }
        $newSiteJsonString .= ",\n";
    }
    $newSiteJsonString .= <<JSON;
        {
            "appconfigid" : "$appConfigId",
            "appid" : "$appId",
JSON

    if( defined( $context )) {
        $newSiteJsonString .= <<JSON;
            "context" : "$context",
JSON
    }
    if( @accs ) {
        $newSiteJsonString .= <<JSON;
            "accessories" : [
JSON
        $newSiteJsonString .= join( '', map { '                ' . $_->packageName . ",\n" } @accs );
            
        $newSiteJsonString .= <<JSON;
            ],
JSON
    }
    if( %$custPointValues ) {
        $newSiteJsonString .= <<JSON;
            "customizationpoints" : {
JSON
        foreach my $packageName ( sort keys %$custPointValues ) {
            my $packageInfo = $custPointValues->{$packageName};

            $newSiteJsonString .= <<JSON;
                "$packageName" : {
JSON
            foreach my $name ( sort keys %$packageInfo ) {
                my $value = $packageInfo->{$value};

                $newSiteJsonString .= <<JSON;
                    "$name" : {
                        "value" : "$value"
                    },
JSON
            }
            $newSiteJsonString .= <<JSON;
                },
JSON
        }
        $newSiteJsonString .= <<JSON;
            }
JSON
    }

    $newSiteJsonString .= <<JSON;
        }
    ]
}
JSON

    if( $dryRun ) {
        print $newSiteJsonString;

    } else {
        my $newSiteJson = UBOS::Utils::readJsonFromString( $newSiteJsonString );
        my $newSite     = new UBOS::Site( $newSiteJson );

        my $prerequisites = {};
        $newSite->addDependenciesToPrerequisites( $prerequisites );
        UBOS::Host::installPackages( $prerequisites );

        $newSite->checkDeployable();

        # May not be interrupted, bad things may happen if it is
        UBOS::Host::preventInterruptions();

        debug( 'Setting up placeholder sites' );

        my $suspendTriggers = {};
        if( $existingSite ) {
            $existingSite->suspend( $suspendTriggers );
        } else {
            $newSite->setupPlaceholder( $suspendTriggers ); # show "coming soon"
        }
        UBOS::Host::executeTriggers( $suspendTriggers );

        my $deployUndeployTriggers = {};
        if( $existingSite ) {
            my $backup = UBOS::UpdateBackup->create( { $siteId => $existingSite } );
            $existingSite->undeploy( $deployUndeployTriggers );
            
            $newSite->deploy( $deployUndeployTriggers );
            $backup->restoreSite( $newSite );

            $backup->delete();
        } else {
            $newSite->deploy( $deployUndeployTriggers );
        }
        UBOS::Host::executeTriggers( $deployUndeployTriggers );

        debug( 'Resuming sites' );

        my $resumeTriggers = {};
        $newSite->resume( $resumeTriggers ); # remove "upgrade in progress page"
        UBOS::Host::executeTriggers( $resumeTriggers );

        debug( 'Running installers' );
        # no need to run any upgraders

        foreach my $appConfig ( @{$newSite->appConfigs} ) {
            $appConfig->runInstaller();
        }

        print "Installed site $siteId at http://$hostname/\n";
    }
    return 1;
}

##
# Ask the user a question
# $q: the question text
# $dontTrim: if false, trim whitespace
# $blank: if true, blank terminal echo
sub ask {
    my $q        = shift;
    my $regex    = shift || '.?';
    my $dontTrim = shift || 0;
    my $blank    = shift;

    my $ret;
    while( 1 ) {
        print $q;

        if( $blank ) {
            system('stty','-echo');
        }
        $ret = <STDIN>;
        if( $blank ) {
            system('stty','echo');
            print "\n";
        }
        unless( $dontTrim ) {
            $ret =~ s!\s+$!!;
            $ret =~ s!^\s+!!;
        }
        if( $ret =~ $regex ) {
            last;
        } else {
            print "(input not valid: regex is $regex)\n";
        }
    }
    return $ret;
}

##
# Return help text for this command.
# return: hash of synopsis to help text
sub synopsisHelp {
    return {
        <<SSS => <<HHH,
    [--verbose | --logConfig <file>]
SSS
    Interactively define and install a new site.
HHH
        <<SSS => <<HHH
    [--verbose | --logConfig <file>] --dry-run | -n
SSS
    Interactively define a new site, but instead of installing,
    print the Site JSON file for the site, which then can be
    deployed using 'ubos-admin deploy'.
HHH
    };
}

1;
