# $Id: 98_homezone.pm 18522 2019-02-07 22:06:35Z KernSani $
##############################################################################
#
#     98_homezone.pm
#     An FHEM Perl module that implements a zone concept in FHEM
#     inspired by https://smartisant.com/research/presence/index.php
#
#     Copyright by KernSani
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################
#     Changelog:
#       0.0.14: Bugfix          -   Unnecessary log messages (Execution failed) removed
#               Bugfix          -   Fixed a bug in attribute validation (occupanyEvent)
#               Feature         -   Configure that "asleep" roommates trigger "present" (hz_sleepRoommates)
#       0.0.13: Bugfix          -   Fixed another bug with diableOnlyCmds
#               Bugfix          -   Fixed a perl warning (uninitialized value in numeric)
#               Feature         -   Added possibility to set inactive for <seconds>
#       0.0.12: Bugfix          -   Fixed buggy diableOnlyCmds
#               Feature         -   $name allowed in perl commands
#               Feature         -   new reading lastChild
#       0.0.11: Bugfix          -   in boxMode incorrectly triggered presence from adjacent zone
#               Feature         -   added diableOnlyCmds Attribute
#       0.0.10: Bugfix          -   Multiline perl
#               Feature         -   Optimized boxMode
#       0.0.09: Bugfix          -   Adjacent zone stuck at occupied 100 in some cases
#               Bugfix          -   boxMode was stopped by timer in adjacent zone
#               Feature         -   Allow Perl in Commands (incl. big textfield to edit)
#               Bugfix          -   adjacent or children attributes could get lost at reload
#       0.0.08: Feature         -   Added disabled-Attributes and set active/inactive
#               Feature         -   Added boxMode
#       0.0.07: Bugfix          -   Fixed a minor bug with lastLumi reading not updating properly
#               Feature         -   Support for multiple doors (wasp-in-a-box)
#       0.0.06: Bugfix          -   Luminance devices not found on startup
#               Bugfix          -   Lumithreshold not properly determined
#               Maintainance    -   Improved Logging
#               Bugfix          -   Parent devices not updating properly
#               Feature         -   Added absenceEvent
#       0.0.05: Maintenance     -   Code cleanup
#               Maintenance     -   Attribute validation and userattr cleanup
#               Bugfix          -   Fixed bug when "close" comes after "occupancy"
#               Feature         -   Some additional readings
#       0.0.04: Feature         -   Added state-dependant commands
#               Feature         -   Added luminance functions
#       0.0.03: Feature         -   Added basic version of daytime-dependant decay value
#       0.0.02: Feature         -   Added "children" attribute
#               Feature         -   List of regexes for Event Attributes
#       0.0.01: initial version
#
##############################################################################

package main;

use strict;
use warnings;

#use Data::Dumper;

my $version = "0.0.13";

###################################
sub homezone_Initialize($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    # Module specific attributes
    my @homezone_attr
        = (   "hz_openEvent"
            . " hz_closedEvent"
            . " hz_occupancyEvent"
            . " hz_absenceEvent"
            . " hz_luminanceReading"
            . " hz_lumiThreshold"
            . " hz_decay"
            . " hz_adjacent"
            . " hz_state"
            . " hz_dayTimes"
            . " hz_multiDoor"
            . " hz_children"
            . " hz_disableOnlyCmds:0,1"
            . " disable:0,1"
            . " disabledForIntervals"
            . " hz_sleepRoommates"
            . " hz_boxMode:0,1" );

    $hash->{SetFn}    = "homezone_Set";
    $hash->{DefFn}    = "homezone_Define";
    $hash->{UndefFn}  = "homezone_Undefine";
    $hash->{NotifyFn} = "homezone_Notify";
    $hash->{AttrFn}   = "homezone_Attr";
    $hash->{AttrList} = join( " ", @homezone_attr ) . " " . $readingFnAttributes;
}

###################################
sub homezone_Define($$) {

    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );

    my $usage = "syntax: define <name> homezone";

    my ( $name, $type ) = @a;
    if ( int(@a) != 2 ) {
        return $usage;
    }

    $hash->{VERSION} = $version;
    $hash->{NAME}    = $name;

    CommandAttr( undef, $name . " hz_state 100:present 50:likely 1:unlikely 0:absent" )
        if ( AttrVal( $name, "hz_state", "" ) eq "" );

    CommandAttr( undef,
        $name
            . " devStateIcon present:user_available\@green likely:user_available\@lightgreen unlikely:user_unknown\@yellow absent:user_away"
    ) if ( AttrVal( $name, "devStateIcon", "" ) eq "" );

    my $dt = "05:00|morning 10:00|day 14:00|afternoon 18:00|evening 23:00|night";
    my @hm = devspec2array("TYPE=HOMEMODE");
    $dt = AttrVal( $hm[1], "homeDayTimes", "" ) if $hm[1];

    CommandAttr( undef, $name . " hz_dayTimes $dt" )
        if ( AttrVal( $name, "hz_dayTimes", "" ) eq "" );

    return undef;
}
###################################
sub homezone_Undefine($$) {

    my ( $hash, $name ) = @_;
    RemoveInternalTimer($hash);
    return undef;
}
###################################
sub homezone_Notify($$) {
    my ( $hash, $dhash ) = @_;
    my $name = $hash->{NAME};    # own name / hash
    my $dev  = $dhash->{NAME};

    return undef
        if ( IsDisabled($name) && AttrVal( $name, "hz_disableOnlyCmds", 0 ) == 0 )
        ;                        # Return without any further action if the module is disabled

    my $events = deviceEvents( $dhash, 1 );

    # Check if children report new state
    my @children = split( ",", AttrVal( $name, "hz_children", "NA" ) );
    if ( grep( /$dev/, @children ) && grep( /occupied/, @{$events} ) ) {
        Log3 $name, 5, "[homezone - $name]: occupied event of child detected";
        my $max = 0;
        my $lastChild;
        foreach my $child (@children) {
            if ( ReadingsNum( $child, "occupied", 0 ) > $max ) {
                $max = ReadingsNum( $child, "occupied", 0 );
                $lastChild = $child;
            }
        }
        homezone_setOcc( $hash, $max, $lastChild );
        return undef;
    }

    # Check for occupied event in adjacent zones
    if ( AttrVal( $name, "hz_boxMode", 0 ) > 0 ) {
        my @zones = split( ",", AttrVal( $name, "hz_adjacent", "NA" ) );
        if ( grep( /$dev/, @zones ) && grep( /occupied/, @{$events} ) ) {
            my $r = ReadingsVal( $dev, "lastZone", "" );
            Log3 $name, 5, "[homezone - $name]: occupied event of adjacent room $dev detected ($r)";
            if ( $r ne "timer" && ReadingsVal( $name, "occupied", 0 ) == 100 ) {

                #homezone_setOpen( $hash, undef );
                homezone_setOcc( $hash, 99, $dev );
            }
            return undef;
        }
    }

    # check for roommates asleep
    my @rm = split( ",", AttrVal( $name, "hz_sleepRoommates", "NA" ) );

    if ( grep( /$dev/, @rm ) && grep( /state:.asleep/, @{$events} ) ) {
        Log3 $name, 5, "[homezone - $name]: roommate $dev asleep detected" . Dumper($events);
        homezone_setOcc( $hash, 100, $dev );
    }
    if ( grep( /$dev/, @rm ) && !( grep( /state:.asleep/, @{$events} ) ) ) {
        Log3 $name, 5, "[homezone - $name]: roommate $dev not asleep anymore";
        my $sleepers = @rm;
        my $i        = 0;
        foreach my $rr (@rm) {
            last if ( ReadingsVal( $rr, "state", "" ) eq "asleep" );
            $i++;
        }
        homezone_setOcc( $hash, 99, $dev ) if ( ReadingsNum( $name, "occupied", 0 ) == 100 && $i == $sleepers );
    }

    # Check open/close/occupancy Events

    # multiple doors
    my @mOpen;
    my $oE = AttrVal( $name, "hz_openEvent", "" );
    if ( $oE ne "" ) {
        @mOpen = split( " ", $oE );
    }

    $hash->{HELPER}{doors} = scalar @mOpen;

    my @mClose;
    my $oC = AttrVal( $name, "hz_closedEvent", "" );
    if ( $oC ne "" ) {
        @mClose = split( " ", $oC );
    }

    my @occ = split( ",", AttrVal( $name, "hz_occupancyEvent", "NA:NA" ) );
    my @abs = split( ",", AttrVal( $name, "hz_absenceEvent",   "NA:NA" ) );

    #return undef if ( !( $dev =~ /$openDev/ or $dev =~ /$closedDev/ or $dev =~ /$occDev/ ) );

    foreach my $event ( @{$events} ) {

        #Log3 $name, 5, "[homezone - $name]: processing event $event for Device $dev";
        my $i = 1;
        foreach my $mO (@mOpen) {
            my @open = split( ",", $mO );

            foreach my $o (@open) {
                my ( $openDev, $openEv ) = split( ":", $o, 2 );
                last if !$openDev;
                if ( $dev =~ /$openDev/ && $event =~ /$openEv/ ) {
                    Log3 $name, 5, "[homezone - $name]: set open (event $openEv)";
                    homezone_setOpen( $hash, $i );
                    last;
                }
            }
            $i++;
        }
        $i = 1;
        foreach my $mO (@mClose) {
            my @close = split( ",", $mO );

            foreach my $c (@close) {
                my ( $closedDev, $closedEv ) = split( ":", $c, 2 );
                if ( $dev =~ /$closedDev/ && $event =~ /$closedEv/ ) {
                    Log3 $name, 5, "[homezone - $name]: set closed (event $closedEv)";
                    homezone_setClosed( $hash, $i );
                    last;
                }
            }
            $i++;
        }
        foreach my $o (@occ) {
            my ( $occDev, $occEv ) = split( ":", $o, 2 );
            if ( $dev =~ /$occDev/ && $event =~ /$occEv/ ) {
                Log3 $name, 5,
                    "[homezone - $name]: set occupancy in condition " . ReadingsVal( $name, "condition", "" );

                #homezone_setClosed( $hash, undef ) if AttrVal( $name, "hz_boxMode", 0 ) > 0;
                my $occ = 99;
                $occ = 100 if AttrVal( $name, "hz_boxMode", 0 ) > 0;
                my @rm = split( ",", AttrVal( $name, "hz_sleepRoommates", "NA" ) );
                foreach my $rr (@rm) {
                    $occ = 100 if ReadingsVal( $rr, "state", "" ) eq "asleep";
                }
                homezone_setOcc( $hash, $occ );
                last;
            }
        }
        foreach my $o (@abs) {
            my ( $absDev, $absEv ) = split( ":", $o, 2 );
            if ( $dev =~ /$absDev/ && $event =~ /$absEv/ ) {
                Log3 $name, 5, "[homezone - $name]: set absence in condition " . ReadingsVal( $name, "condition", "" );
                homezone_setOcc( $hash, 0 );
                last;
            }
        }

    }

    return undef;
}

###################################
sub homezone_setOcc($$;$) {
    my ( $hash, $occ, $lastChild ) = @_;
    my $name = $hash->{NAME};

    $lastChild = "self" unless $lastChild;

    if ( ReadingsVal( $name, "condition", "" ) eq "closed" && $lastChild ne "timer" ) {
        $occ = 100;
    }

    # Determine state
    my $oldState = ReadingsVal( $name, "state", "" );
    my $stats = AttrVal( $name, "hz_state", "" );
    my $stat = $occ;
    if ( $stats ne "" ) {
        my %params = map { split /\:/, $_ } ( split /\ /, $stats );
        foreach my $param ( reverse sort { $a <=> $b } keys %params ) {
            if ( $occ >= $param ) {
                $stat = $params{$param};
                last;
            }
        }
    }

    # State changed --> Execute command
    my $lumi = 0;
    my $lumiReading = AttrVal( $name, "hz_luminanceReading", "" );
    if ( $lumiReading ne "" ) {
        my ( $d, $r ) = split( ":", $lumiReading );
        $lumi = ReadingsNum( $d, $r, 0 );
    }

    if ( $stat ne $oldState && IsDisabled($name) == 0 ) {
        my $cmd = AttrVal( $name, "hz_cmd_" . $stat, "" );
        $cmd =~ s/^(\n|[ \t])*//;    # Strip space or \n at the begginning
        $cmd =~ s/[ \t]*$//;

        #my $lumiThresholds = AttrVal( $name, "hz_lumiThreshold_" . $stat, "" );
        #my $lumiTh = ReadingsVal( $name, "hz_lumiThreshold", 0 );
        my ( $low, $high )
            = split( ":",
            AttrVal( $name, "hz_lumiThreshold_" . $stat, AttrVal( $name, "hz_lumiThreshold", "0:9999999999" ) ) );

        $low  = 0         if ( !$low );
        $high = 999999999 if ( !$high );
        Log3 $name, 5, "[homezone - $name]: Luminance: $lumi Threshold: $low-$high";

        if ( $lumi >= $low and $lumi <= $high ) {
            my %specials = ( "%name" => $name );
            $cmd = EvalSpecials( $cmd, %specials );
            if ( $cmd ne '' ) {
                Log3 $name, 5, "[homezone - $name]: Executing '$cmd' for $stat";
                my $ret = AnalyzeCommandChain( undef, "$cmd" ) unless ( $cmd eq "" or $cmd =~ m/^{.*}$/s );
                Log3 $name, 1, "[homezone - $name]: Command execution failed: $ret" if ($ret);
                $ret = AnalyzePerlCommand( undef, $cmd ) if ( $cmd =~ m/^{.*}$/s );
                Log3 $name, 1, "[homezone - $name]: Perl execution failed: $ret" if ($ret);
            }
        }
    }

    # update adjacent zones
    my $adj = AttrVal( $name, "hz_adjacent", "" );
    if ( $adj ne "" && AttrVal( $name, "hz_boxMode", 0 ) == 0 ) {
        my @adj = split( ",", $adj );
        foreach $a (@adj) {
            my $aOcc = ReadingsNum( $a, "occupied", 0 );
            if ( $aOcc < $occ && $aOcc > 0 ) {
                AnalyzeCommandChain( undef, "set $a occupied $occ $name" );
            }
        }
    }
    my $leafChild = ReadingsVal( $lastChild, "lastChild", "" );
    if (    $leafChild eq ""
        and AttrVal( $name, "hz_children", "NA" ) ne "NA"
        and grep( $lastChild, split( ",", AttrVal( $name, "hz_children", "NA" ) ) ) )
    {
        $leafChild = $lastChild;
    }

    # update readings
    readingsBeginUpdate($hash);
    readingsBulkUpdate( $hash, "occupied",  $occ );
    readingsBulkUpdate( $hash, "state",     $stat );
    readingsBulkUpdate( $hash, "lastLumi",  $lumi ) if $lumiReading ne "";
    readingsBulkUpdate( $hash, "lastZone",  $lastChild );
    readingsBulkUpdate( $hash, "lastChild", $leafChild ) if $leafChild ne "";
    readingsEndUpdate( $hash, 1 );

    homezone_startTimer($hash);
}

###################################
sub homezone_setOpen($$) {
    my ( $hash, $door ) = @_;
    my $name = $hash->{NAME};
    my $cond = "open";
    if ( $hash->{HELPER}{doors} > 1 ) {
        readingsSingleUpdate( $hash, "door" . $door, "open", 0 );
        $cond = homezone_getDoorState($hash);
    }
    readingsSingleUpdate( $hash, "condition", $cond, 1 );
    if ( ReadingsNum( $name, "occupied", 0 ) == 100 ) {

        # check if adjacent was set to 100 by current zone
        my $adj = AttrVal( $name, "hz_adjacent", "" );
        if ( $adj ne "" && AttrVal( $name, "hz_boxMode", 0 ) == 0 ) {
            my @adj = split( ",", $adj );
            foreach $a (@adj) {
                my $aOcc = ReadingsNum( $a, "occupied", 0 );
                my $alz = ReadingsVal( $a, "lastZone", "" );
                if ( $aOcc == 100 && $alz eq $name ) {
                    AnalyzeCommandChain( undef, "set $a open" );
                }
            }
        }
        homezone_setOcc( $hash, 99 );
    }

}

###################################
sub homezone_setClosed($$) {
    my ( $hash, $door ) = @_;
    my $name = $hash->{NAME};
    my $cond = "closed";
    if ( $hash->{HELPER}{doors} > 1 ) {
        readingsSingleUpdate( $hash, "door" . $door, "closed", 0 );
        $cond = homezone_getDoorState($hash);
    }
    readingsSingleUpdate( $hash, "condition", $cond, 1 );
}

###################################
sub homezone_Set($@) {
    my ( $hash, @a ) = @_;
    my $name = $hash->{NAME};

    return "no set value specified" if ( int(@a) < 2 );
    my $usage = "Unknown argument $a[1], choose one of active:noArg inactive occupied closed open";

    if ( $a[1] eq "inactive" ) {
        return "If an argument is given for $a[1] it has to be a number (in seconds)"
            if ( $a[2] && !( $a[2] =~ /^\d+$/ ) );
        RemoveInternalTimer( $hash, "homezone_ProcessTimer" );
        readingsSingleUpdate( $hash, "state", "inactive", 1 );
        if ( $a[2] ) {
            Log3 $name, 1, "Timer: $a[2]";
            my $tm = int( gettimeofday() ) + int( $a[2] );
            $hash->{HELPER}{ActiveTimer} = "inactive";
            InternalTimer( $tm, 'homezone_setActive', $hash, 0 );
        }
    }
    elsif ( $a[1] eq "active" ) {
        RemoveInternalTimer( $hash, "homezone_setActive" );
        if ( IsDisabled($name) ) {    #&& !AttrVal( $name, "disable", undef ) ) {
            readingsSingleUpdate( $hash, "state", "initialized", 1 );
        }
        else {
            return "[homezone - $name]: is already active";
        }
    }
    elsif ( $a[1] eq "occupied" ) {
        if ( $a[2] < 0 or $a[2] > 100 ) {
            return "Argument has to be between 0 and 100";
        }
        homezone_setOcc( $hash, $a[2], $a[3] )
            unless ( IsDisabled($name) && AttrVal( $name, "hz_disableOnlyCmds", 0 ) == 0 );
    }
    elsif ( $a[1] eq "open" ) {
        return "Argument has to be a number between 1 and $hash->{HELPER}{doors}"
            if (
            $hash->{HELPER}{doors}
            && (   $hash->{HELPER}{doors} > 1 and $a[2] < 1
                or $a[2] > $hash->{HELPER}{doors} )
            );
        homezone_setOpen( $hash, $a[2] ) unless ( IsDisabled($name) && AttrVal( $name, "hz_disableOnlyCmds", 0 ) == 0 );
    }
    elsif ( $a[1] eq "closed" ) {
        return "Argument has to be a number between 1 and $hash->{HELPER}{doors}"
            if $hash->{HELPER}{doors} > 1 and $a[2] < 1
            or $a[2] > $hash->{HELPER}{doors};
        homezone_setClosed( $hash, $a[2] )
            unless ( IsDisabled($name) && AttrVal( $name, "hz_disableOnlyCmds", 0 ) == 0 );
    }
    else {
        return $usage;
    }
    return undef;
}
###################################
sub homezone_setActive($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    if ( IsDisabled($name) ) {
        readingsSingleUpdate( $hash, "state", "initialized", 1 );
    }

}
###################################
sub homezone_startTimer($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    RemoveInternalTimer($hash);

    my $d = homezone_decay($hash);
    my $occupied = ReadingsVal( $name, "occupied", 0 );
    Log3 $name, 5, "[homezone - $name]: $occupied";
    if ( $d > 0 && $occupied < 100 && $occupied > 0 ) {
        my $step = $d / 10;
        my $now  = gettimeofday();
        $hash->{helper}{TIMER} = int($now) + $step;
        InternalTimer( $hash->{helper}{TIMER}, 'homezone_ProcessTimer', $hash, 0 );
    }

}

###################################
sub homezone_ProcessTimer($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $occupied = ReadingsVal( $name, "occupied", 0 );
    my $pct = int( ( $occupied - 10 ) / 10 + 0.5 ) * 10;
    homezone_setOcc( $hash, $pct, "timer" );
}

###################################
sub homezone_Attr($) {

    my ( $cmd, $name, $aName, $aVal ) = @_;
    my $hash = $defs{$name};

    # . " hz_adjacent"
    # . " hz_children" );

    # $cmd can be "del" or "set"
    # $name is device name
    # aName and aVal are Attribute name and value
    #Log3 $name, 3, "$cmd $aName $aVal";
    if ( $cmd eq "set" ) {
        if ( $aName eq "hz_dayTimes" && $init_done ) {
            my $oVals = AttrVal( $name, "hz_dayTimes", "" );
            my @oldVals = map { ( split /\|/, $_ )[1] } split( " ", $oVals );

            my $bVal = $aVal;
            $bVal =~ s/\$SUNRISE/00:00/;
            $bVal =~ s/\$SUNSET/00:00/;
            return "$aName must be a space separated list of time|text pairs"
                if ( $bVal !~ /^([0-2]\d:[0-5]\d\|[\w\-äöüß\.]+)(\s[0-2]\d:[0-5]\d\|[\w\-äöüß\.]+){0,}$/i );

            my @newVals = map { ( split /\|/, $_ )[1] } split( " ", $aVal );
            my $userattr = AttrVal( $name, "userattr", "" );

            # create new userattributes if required
            foreach my $text (@newVals) {
                if ( grep ( /^$text$/, @oldVals ) ) {
                    @oldVals = grep { $_ ne $text } @oldVals;
                }
                else {
                    my $ua = " hz_decay_" . $text;
                    $userattr .= $ua;
                }
            }

            # delete old Attributes
            foreach my $o (@oldVals) {
                my $r = "hz_decay_" . $o;
                $userattr =~ s/$r/ /;
                CommandDeleteAttr( undef, "$name hz_decay_" . $o );
            }

            # update userattr
            CommandAttr( undef, "$name userattr $userattr" );
        }
        elsif ( $aName eq "hz_state" ) {
            foreach my $a ( split( " ", $aVal ) ) {
                return "$aName must be a space separated list of probability:text pairs"
                    if ( !( $a =~ /(1\d\d|\d\d|\d):([\w\-äöüß\.]+)/ ) );
            }
            my $oVals = AttrVal( $name, "hz_state", "" );
            my @oldVals = map { ( split /:/, $_ )[1] } split( " ", $oVals );
            Log3 $name, 5, "[homezone - $name]: Old States - " . join( " ", @oldVals );

            my @newVals = map { ( split /:/, $_ )[1] } split( " ", $aVal );
            Log3 $name, 5, "[homezone - $name]: New States - " . join( " ", @newVals );

            my $userattr = AttrVal( $name, "userattr", "" );

            foreach my $text (@newVals) {
                if ( grep ( /^$text$/, @oldVals ) ) {
                    @oldVals = grep { $_ ne $text } @oldVals;
                    Log3 $name, 5, "[homezone - $name]: no update for $text ";
                }
                else {
                    my $ua = " hz_cmd_" . $text . ":textField-long";
                    $userattr .= $ua;
                    my $ua2 = " hz_lumiThreshold_" . $text;
                    $userattr .= $ua2;
                    Log3 $name, 5, "[homezone - $name]: new user attributes created for $text ";
                }
            }

            foreach my $o (@oldVals) {
                my $r = "hz_cmd_" . $o;
                $userattr =~ s/$r/ /;
                CommandDeleteAttr( undef, "$name $r" );
                $r = "hz_lumiThreshold_" . $o;
                $userattr =~ s/$r/ /;
                CommandDeleteAttr( undef, "$name $r" );
                Log3 $name, 5, "[homezone - $name]: user attributes deleted for $r";
            }

            # update userattr
            CommandAttr( undef, "$name userattr $userattr" );

        }
        elsif (
            (      $aName eq "hz_openEvent"
                or $aName eq "hz_closedEvent"
                or $aName eq "hz_occupancyEvent"
                or $aName eq "hz_absenceEvent"
            )
            && $init_done
            )
        {
            #my @aw = split(" ",ReadingsVal($name,"associatedWith",""));
            my @md = split( " ", $aVal );
            foreach my $ma (@md) {
                Log3 $name, 1, $ma;
                foreach my $a ( split( ",", $ma ) ) {
                    my ( $d, $e ) = split( ":", $a, 2 );
                    return "$d is not a valid device" if ( devspec2array($d) eq $d && !$defs{$d} );
                    return "Event not defined for $d" if ( !$e or $e eq "" );

                    #foreach my $awd (devspec2array($d)) {
                    #   push(@aw, $awd) unless grep (/$d/, @aw);
                    #}
                }
            }

            #readingsSingleUpdate($hash,"associatedWith",join(" ",@aw),0);
        }
        elsif ( $aName eq "hz_luminanceReading" && $init_done ) {
            my ( $d, $r ) = split( ":", $aVal );
            return "Couldn't get a luminance value for reading $r of device $d" if ReadingsVal( $d, $r, "" ) eq "";

            #my @aw = split(" ",ReadingsVal($name,"associatedWith",""));
            #push(@aw, $d) unless grep (/$d/, @aw);
            #readingsSingleUpdate($hash,"associatedWith",join(" ",@aw),0);
        }
        elsif ( $aName =~ /hz_lumiThreshold.*/ ) {
            return "$aName has to be in the form <low>:<high>" unless $aVal =~ /.*:.*/;
        }
        elsif ( $aName =~ /hz_decay.*/ ) {
            return "$aName should be a number (in seconds)" unless $aVal =~ /^\d+$/;
        }
        elsif ( ( $aName eq "hz_adjacent" or $aName eq "hz_children" ) && $init_done ) {
            foreach my $a ( split( ",", $aVal ) ) {
                return "$a is not a homezone Device" if InternalVal( $a, "TYPE", "" ) eq "";

                #my @aw = split(" ",ReadingsVal($name,"associatedWith",""));
                #push(@aw, $a) unless grep (/$a/, @aw);
                #readingsSingleUpdate($hash,"associatedWith",join(" ",@aw),0);

            }
        }
        elsif ( $aName =~ /hz_cmd_.*/ ) {
            if ( $aVal =~ m/^{.*}$/s ) {
                my %specials = ( "%name" => $name );

                #my $cmd = EvalSpecials($aVal, %specials);
                my $err = perlSyntaxCheck( $aVal, %specials );
                return $err if ($err);
            }

        }
        elsif ( $aName eq "disable" ) {
            if ( $aVal == 1 ) {
                RemoveInternalTimer($hash);
                readingsSingleUpdate( $hash, "state", "inactive", 1 );
            }
            elsif ( $aVal == 0 ) {
                readingsSingleUpdate( $hash, "state", "initialized", 1 );
            }

        }

    }
    elsif ( $cmd eq "del" ) {
        if ( $aName eq "disable" ) {
            readingsSingleUpdate( $hash, "state", "initialized", 1 );
        }

    }

    return undef;

}
###################################################################
# HELPER functions
###################################################################

sub homezone_dayTime($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $daytimes = AttrVal( $name, "hz_dayTimes", "NA" );
    return "" if $daytimes eq "NA";

    my ( $sec, $min, $hour, $mday, $month, $year, $wday, $yday, $isdst ) = localtime;
    my $loctime = $hour * 60 + $min;
    my @texts;
    my @times;
    foreach ( split " ", $daytimes ) {
        my ( $dt, $text ) = split /\|/;
        $dt = sunrise_abs() if $dt eq "\$SUNRISE";
        $dt = sunset_abs()  if $dt eq "\$SUNSET";
        my ( $h, $m, $s ) = split /:/, $dt;
        my $minutes = $h * 60 + $m;
        push @times, $minutes;
        push @texts, $text;
    }
    my $daytime = $texts[ scalar @texts - 1 ];
    for ( my $x = 0; $x < scalar @times; $x++ ) {
        my $y = $x + 1;
        $y = 0 if ( $x == scalar @times - 1 );
        $daytime = $texts[$x] if ( $y > $x && $loctime >= $times[$x] && $loctime < $times[$y] );
    }
    readingsSingleUpdate( $hash, "lastDayTime", $daytime, 0 );
    return $daytime;
}

###################################
sub homezone_decay($) {
    my ($hash) = @_;
    my $name   = $hash->{NAME};
    my $dt     = homezone_dayTime($hash);
    $dt = "_" . $dt if $dt ne "";
    return AttrVal( $name, "hz_decay" . $dt, AttrVal( $name, "hz_decay", 0 ) );
}

###################################
sub homezone_getDoorState($) {
    my ($hash) = @_;
    my $name   = $hash->{NAME};
    my $open   = 0;
    my $i      = 1;
    while ( $i <= $hash->{HELPER}{doors} ) {
        if ( ReadingsVal( $name, "door" . $i, "" ) eq "open" ) {
            $open++;
        }
        $i++;
    }
    Log3 $name, 5, "[homezone - $name]: Found $open open doors out of $hash->{HELPER}{doors}";
    return "open"   if ( $open == $hash->{HELPER}{doors} );
    return "closed" if ( $open == 0 );
    return "partly closed";
}

1;

=pod
=item helper
=item summary realizes a zone concept for presence-dependent automation
=item summary_DE implementiert ein Zonenkonzept für anwesenheitsbasierte Automatisierung
=begin html

<a name="homezone"></a>
<h3>homezone</h3>
<div>
    <ul>The idea of homezone is to create "zones" in your home, to detect presence within a zone as accurate as possible and thus be able to precisely control that zone based on presence. homezone is partly inspired by this article: <a href=https://smartisant.com/research/presence/index.php>https://smartisant.com/research/presence/index.php</a>.<br><br>
    The challenge with presence detection based on motion sensors is that it is not very reliable in case you're not moving. homezone tries to overcome those challenges with various concepts:
    <b>Probability of Presence:</b> If motion (or another signal that indicates presence, like pushing a button) is detected, it's very likely that someone is present. The longer no presence-signal is received, the more unlikely it becomes that someone is present. Thus homezone has a counter that decreases the likelyhood of presence if no signal is received until it finally becomes 0.<br>
    <b>Closed zones:</b> If a room is closed, i.e. e.g. all doors are closed and presence is detected, you can be sure that someone is present - until a door is opened. Thus probability of presence will remain 100% after motion is detected in a closed zone. The counter will only start to decrease after it is opened again.
    (..)
    </ul>
    
    

=end html

=begin html_DE

<a name="homezone"></a>
<h3>homezone</h3>

=end html_DE
=cut

