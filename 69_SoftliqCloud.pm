# $Id: 98_SoftliqCloud.pm 21368 2020-03-06 22:58:24Z KernSani $
##############################################################################
#
#     98_SoftliqCloud.pm
#     An FHEM Perl module that retrieves information from SoftliqCloud
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
#     20.02.2020    Parsing of grouped classes
##############################################################################
##############################################################################
#     Todo:
#
#
##############################################################################

package main;
use strict;
use warnings;
use DevIo;

package FHEM::SoftliqCloud;

use HttpUtils;
use Data::Dumper;
use FHEM::Meta;
use GPUtils qw(GP_Import GP_Export);
use utf8;
use POSIX qw( strftime );

# IO::Socket::SSL lets us open encrypted (wss) connections
use IO::Socket::SSL;

# IO::Select to "peek" IO::Sockets for activity
use IO::Select;

# Protocol handler for WebSocket HTTP protocol

my $missingModul = "";
eval "use MIME::Base64::URLSafe;1"                 or $missingModul .= "MIME::Base64::URLSafe; ";
eval "use Digest::SHA qw(sha256);1;"               or $missingModul .= "Digest::SHA ";
eval "use JSON::XS qw (encode_json decode_json);1" or $missingModul .= "JSON::XS ";
eval "use Protocol::WebSocket::Client;1"           or $missingModul .= "Protocol::WebSocket::Client ";

#-- Export to main context with different name
GP_Export(
    qw(
        Initialize
        )
);

sub Initialize {
    my ($hash) = @_;

    #$hash->{SetFn}    = 'FHEM::SoftliqCloud::Set';
    $hash->{GetFn} = 'FHEM::SoftliqCloud::Get';
    $hash->{DefFn} = 'FHEM::SoftliqCloud::Define';
    $hash->{Ready} = 'FHEM::SoftliqCloud::Ready';
    $hash->{Read}  = 'FHEM::SoftliqCloud::wsReadDevIo';

    #$hash->{NotifyFn} = 'FHEM::SoftliqCloud::Notify';
    $hash->{UndefFn} = 'FHEM::SoftliqCloud::Undefine';

    #$hash->{AttrFn}   = 'FHEM::SoftliqCloud::Attr';
    my @SQattr = ( "sq_user " . "sq_password " );

    #$hash->{AttrList} = join( " ", @SQattr ) . " " . $::readingFnAttributes;

    $hash->{AttrList} = $::readingFnAttributes;

    return FHEM::Meta::InitMod( __FILE__, $hash );
}
###################################
sub Define {
    my $hash = shift;
    my $def  = shift;

    return $@ unless ( FHEM::Meta::SetInternals($hash) );

    my @a = split( "[ \t][ \t]*", $def );

    my $usage = "syntax: define <name> SoftliqCloud <loginName> <password>";
    return "Cannot define device. Please install perl modules $missingModul."
        if ($missingModul);
    my ( $name, $type, $user, $pass ) = @a;
    if ( int(@a) != 4 ) {
        return $usage;
    }

    main::Log3 $name, 3, "[$name] SoftliqCloud defined $name";

    $hash->{NAME} = $name;
    $hash->{USER} = $user;
    $hash->{PASS} = $pass;

    #start timer
    if ($::init_done) {
        my $next = int( main::gettimeofday() ) + 1;
        main::InternalTimer( $next, 'FHEM::SoftliqCloud::sqTimer', $hash, 0 );
    }
    return;
}
###################################
sub Undefine {
    my $hash = shift;
    main::RemoveInternalTimer($hash);
    return;
}
###################################
sub Get {
    my $hash = shift;
    my $name = shift;
    my $cmd  = shift // return "set $name needs at least one argument";

    if ( $cmd eq 'authenticate' ) {
        push @{ $hash->{helper}{cmdQueue} }, \&authenticate;
        push @{ $hash->{helper}{cmdQueue} }, \&login;
        push @{ $hash->{helper}{cmdQueue} }, \&getCode;
        push @{ $hash->{helper}{cmdQueue} }, \&initToken;
        processCmdQueue($hash);
        return;
    }
    if ( $cmd eq 'devices' ) {
        push @{ $hash->{helper}{cmdQueue} }, \&getRefreshToken;
        push @{ $hash->{helper}{cmdQueue} }, \&getDevices;
        processCmdQueue($hash);
        return;
    }
    if ( $cmd eq 'param' ) {
        push @{ $hash->{helper}{cmdQueue} }, \&getParam;
        processCmdQueue($hash);
        return;
    }

    if ( $cmd eq 'info' ) {
        push @{ $hash->{helper}{cmdQueue} }, \&getRefreshToken;
        push @{ $hash->{helper}{cmdQueue} }, \&getInfo;
        processCmdQueue($hash);
        return;
    }
    if ( $cmd eq 'water' || $cmd eq 'salt' ) {
        return getMeasurements( $hash, $cmd );
    }

    return negotiate($hash) if ( $cmd eq 'realtime' );

    #return getRefreshToken($hash) if ( $cmd eq 'refreshToken' );
    return realtime($hash) if ( $cmd eq 'realtime' );

    return query($hash) if ( $cmd eq 'query' );

    return "Unknown argument $cmd, choose one of realtime:noArg  water:noArg salt:noArg query:noArg";
}
###################################
sub sqTimer {
    my $hash = shift;

    my $name = $hash->{NAME};
    query($hash);
    main::Log3 $name, 3, qq([$name]: Starting Timer);
    my $next = int( main::gettimeofday() ) + 3600;
    main::InternalTimer( $next, 'FHEM::SoftliqCloud::sqTimer', $hash, 0 );
}

sub query {
    my $hash = shift;

    my $name = $hash->{NAME};
    main::Log3 $name, 1, "================>>>>>>>>>>> " . isExpiredToken($hash);
    if ( main::ReadingsVal( $name, 'accessToken', '' ) eq '' || isExpiredToken($hash) ) {
        push @{ $hash->{helper}{cmdQueue} }, \&authenticate;
        push @{ $hash->{helper}{cmdQueue} }, \&login;
        push @{ $hash->{helper}{cmdQueue} }, \&getCode;
        push @{ $hash->{helper}{cmdQueue} }, \&initToken;
    }
    push @{ $hash->{helper}{cmdQueue} }, \&getRefreshToken;
    push @{ $hash->{helper}{cmdQueue} }, \&getDevices;
    push @{ $hash->{helper}{cmdQueue} }, \&getInfo;
    push @{ $hash->{helper}{cmdQueue} }, \&getParam;
    push @{ $hash->{helper}{cmdQueue} }, \&negotiate;
    processCmdQueue($hash);

}

sub isExpiredToken {
    my $hash = shift;
    my $name = $hash->{NAME};

    my $now = main::gettimeofday();
    my $expires = main::ReadingsVal( $name, "expires_on", '1900-01-01' );
    main::Log3 $name, 5, main::time_str2num($expires) - 60 . "- $now";
    if ( main::time_str2num($expires) - 60 > $now ) {
        return 1;
    }
    return;
}

sub authenticate {
    my $hash = shift;
    my $name = $hash->{NAME};

    # if ( main::AttrVal( $name, 'sq_user', '' ) eq '' || main::AttrVal( $name, 'sq_password', '' ) eq '' ) {
    #     return "Please maintain user and password attributes first";
    # }

    if ( !exists &{"urlsafe_b64encode"} ) {
        main::Log3 $name, 1, "urlsafe_b64encode doesn't exist. Exiting";
        return;
    }

    my $auth_code_verifier
        = urlsafe_b64encode( join( '', map { ( 'a' .. 'z', 'A' .. 'Z', 0 .. 9 )[ rand 62 ] } 0 .. 31 ) );
    $auth_code_verifier =~ s/=//;
    $hash->{helper}{code_verifier} = $auth_code_verifier;

    my $auth_code_challenge = urlsafe_b64encode( sha256($auth_code_verifier) );
    $auth_code_challenge =~ s/\=//;
    my $param->{header} = {
        "Accept"          => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Encoding" => "br, gzip, deflate",
        "Connection"      => "keep-alive",
        "Accept-Language" => "de-de",
        "User-Agent" =>
            "Mozilla/5.0 (iPhone; CPU iPhone OS 12_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1"
    };
    my $url
        = "https://gruenbeckb2c.b2clogin.com/a50d35c1-202f-4da7-aa87-76e51a3098c6/b2c_1_signinup/oauth2/v2.0/authorize?state=NzZDNkNBRkMtOUYwOC00RTZBLUE5MkYtQTNFRDVGNTQ3MUNG"
        . "&x-client-Ver=0.2.2"
        . "&prompt=select_account"
        . "&response_type=code"
        . "&code_challenge_method=S256"
        . "&x-client-OS=12.4.1"
        . "&scope=https%3A%2F%2Fgruenbeckb2c.onmicrosoft.com%2Fiot%2Fuser_impersonation+openid+profile+offline_access"
        . "&x-client-SKU=MSAL.iOS"
        . "&code_challenge="
        . $auth_code_challenge
        . "&x-client-CPU=64"
        . "&client-request-id=FDCD0F73-B7CD-4219-A29B-EE51A60FEE3E&redirect_uri=msal5a83cc16-ffb1-42e9-9859-9fbf07f36df8%3A%2F%2Fauth&client_id=5a83cc16-ffb1-42e9-9859-9fbf07f36df8&haschrome=1"
        . "&return-client-request-id=true&x-client-DM=iPhone";
    $param->{method}   = "GET";
    $param->{url}      = $url;
    $param->{callback} = \&parseAuthenticate;
    $param->{hash}     = $hash;

    #$param->{ignoreredirects} = 1;

    main::Log3 $name, 5, "1st Generated URL is $param->{url}";

    my ( $err, $data ) = main::HttpUtils_NonblockingGet($param);
    return;
}

sub parseAuthenticate {
    my ( $param, $err, $data ) = @_;
    my $hash   = $param->{hash};
    my $name   = $hash->{NAME};
    my $header = $param->{httpheader};

    my $cookies = getCookies( $hash, $header );

    #main::Log3 undef, 1, $err . " / " . $data;
    my $cdata = $data;
    my @res   = $cdata =~ /\"csrf\":\"(.*?)\",.*\"transId\":\"(.*?)\",.*\"tenant\":\"(.*?)\",.*\"policy\":\"(.*?)\",/gm;
    my $csrf  = $res[0];
    $hash->{helper}{csrf}    = $csrf;
    $hash->{helper}{tenant}  = $res[2];
    $hash->{helper}{policy}  = $res[3];
    $hash->{helper}{transId} = $res[1];
    main::Log3 $name, 5, Dumper(@res);    # . "\n-" . Dumper($header);    #  ."-". $tenant

    main::readingsSingleUpdate( $hash, "tenant", $hash->{helper}{tenant}, 0 );

    #my $cookies;
    if ( $hash->{HTTPCookieHash} ) {
        foreach my $cookie ( sort keys %{ $hash->{HTTPCookieHash} } ) {
            my $cPath = $hash->{HTTPCookieHash}{$cookie}{Path};
            $cookies .= "; " if ($cookies);
            $cookies .= $hash->{HTTPCookieHash}{$cookie}{Name} . "=" . $hash->{HTTPCookieHash}{$cookie}{Value};
        }
    }
    $hash->{helper}{cookies} = $cookies;
    processCmdQueue($hash);
    return;
}

sub login {
    my $hash = shift;
    my $name = $hash->{NAME};

    my $newheader = {
        "Content-Type"     => "application/x-www-form-urlencoded; charset=UTF-8",
        "X-CSRF-TOKEN"     => $hash->{helper}{csrf},
        "Accept"           => "application/json, text/javascript, */*; q=0.01",
        "X-Requested-With" => "XMLHttpRequest",
        "Origin"           => "https://gruenbeckb2c.b2clogin.com",
        "Referer" =>
            "https://gruenbeckb2c.b2clogin.com/a50d35c1-202f-4da7-aa87-76e51a3098c6/b2c_1_signinup/oauth2/v2.0/authorize?state=MTgxQUExQ0QtN0NFMi00NkE1LTgyQTQtNEY0NEREMDYzMTM2&x-client-Ver=0.2.2&prompt=select_account&response_type=code&code_challenge_method=S256&x-client-OS=13.3.1&scope=https%3A%2F%2Fgruenbeckb2c.onmicrosoft.com%2Fiot%2Fuser_impersonation+openid+profile+offline_access&x-client-SKU=MSAL.iOS&code_challenge=z3tSf1frNKpNB0TTGb6VKrLLHwNFvII7c75sv1CG9Is&x-client-CPU=64&client-request-id=1A472478-12F4-445D-81AC-170A578B4F37&redirect_uri=msal5a83cc16-ffb1-42e9-9859-9fbf07f36df8%3A%2F%2Fauth&client_id=5a83cc16-ffb1-42e9-9859-9fbf07f36df8&haschrome=1&return-client-request-id=true&x-client-DM=iPhone",
        "Cookie" => $hash->{helper}{cookies},
        "User-Agent" =>
            "Mozilla/5.0 (iPhone; CPU iPhone OS 12_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1"
    };
    my $newdata = {
        "request_type"    => 'RESPONSE',
        "logonIdentifier" => main::InternalVal( $name, 'USER', '' ),
        "password"        => main::InternalVal( $name, 'PASS', '' )
    };

    my $newparam = {
        header      => $newheader,
        hash        => $hash,
        method      => "POST",
        httpversion => "1.1",
        timeout     => 10,
        url         => "https://gruenbeckb2c.b2clogin.com"
            . $hash->{helper}{tenant}
            . "/SelfAsserted?tx="
            . $hash->{helper}{transId} . "&p="
            . $hash->{helper}{policy},
        callback => \&parseLogin,
        data     => $newdata

    };

    main::Log3 $name, 5, "Generated URL is $newparam->{url} \n";

    main::HttpUtils_NonblockingGet($newparam);
    return;
}

sub parseLogin {

    my ( $param, $err, $data ) = @_;
    my $hash   = $param->{hash};
    my $name   = $hash->{NAME};
    my $header = $param->{httpheader};

    # $data should be {"status":"200"}
    main::Log3 $name, 5, $err . " / " . $data;

    my $cookies = getCookies( $hash, $header );
    if ( $hash->{HTTPCookieHash} ) {
        foreach my $cookie ( sort keys %{ $hash->{HTTPCookieHash} } ) {
            my $cPath = $hash->{HTTPCookieHash}{$cookie}{Path};
            $cookies .= "; " if ($cookies);
            $cookies .= $hash->{HTTPCookieHash}{$cookie}{Name} . "=" . $hash->{HTTPCookieHash}{$cookie}{Value};
        }
    }

    main::Log3 $name, 5, "=================" . Dumper($cookies) . "\nHeader:" . Dumper($header);
    $cookies .= "; x-ms-cpim-csrf=" . $hash->{helper}{csrf};
    main::Log3 $name, 5, "=================" . Dumper($cookies) . "\n";
    $hash->{helper}{cookies} = $cookies;
    processCmdQueue($hash);
    return;
}

sub getCode {
    my $hash = shift;
    my $name = $hash->{NAME};

    my $newparam->{header} = {
        "Accept"          => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Encoding" => "br, gzip, deflate",
        "Connection"      => "keep-alive",
        "Accept-Language" => "de-de",
        "Cookie"          => $hash->{helper}{cookies},
        "User-Agent" =>
            "Mozilla/5.0 (iPhone; CPU iPhone OS 12_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1"
    };
    $newparam->{url}
        = "https://gruenbeckb2c.b2clogin.com"
        . $hash->{helper}{tenant}
        . "/api/CombinedSigninAndSignup/confirmed?csrf_token="
        . $hash->{helper}{csrf} . "&tx="
        . $hash->{helper}{transId} . "&p="
        . $hash->{helper}{policy};

    $newparam->{hash} = $hash;

    $newparam->{callback}        = \&parseCode;
    $newparam->{httpversion}     = "1.1";
    $newparam->{ignoreredirects} = 1;
    main::Log3 $name, 5, qq(Calling $newparam->{url});
    main::HttpUtils_NonblockingGet($newparam);

    return;
}

sub parseCode {
    my ( $param, $err, $data ) = @_;
    my $hash   = $param->{hash};
    my $name   = $hash->{NAME};
    my $header = $param->{httpheader};

    my $cookies = getCookies( $hash, $header );
    main::Log3 $name, 5, qq($err / $data);

    my @code = $data =~ /code%3d(.*)\">here/;
    return unless $code[0] ne "";

    main::Log3 $name, 5, Dumper(@code);
    $hash->{helper}{code} = $code[0];
    processCmdQueue($hash);
    return;
}

sub initToken {
    my $hash = shift;
    my $name = $hash->{NAME};

    my $newparam->{header} = {
        "Host"                     => "gruenbeckb2c.b2clogin.com",
        "x-client-SKU"             => "MSAL.iOS",
        "Accept"                   => "application/json",
        "x-client-OS"              => "12.4.1",
        "x-app-name"               => "Gruenbeck",
        "x-client-CPU"             => "64",
        "x-app-ver"                => "1.0.7",
        "Accept-Language"          => "de-de",
        "Accept-Encoding"          => "br, gzip, deflate",
        "client-request-id"        => "1A472478-12F4-445D-81AC-170A578B4F37",
        "User-Agent"               => "Gruenbeck/333 CFNetwork/1121.2.2 Darwin/19.3.0",
        "x-client-Ver"             => "0.2.2",
        "x-client-DM"              => "iPhone",
        "return-client-request-id" => "true",

        #        "cache-control"            => "no-cache",
        "Connection"               => "keep-alive",
        "Content-Type"             => "application/x-www-form-urlencoded",
        "return-client-request-id" => "true"
    };
    $newparam->{url} = "https://gruenbeckb2c.b2clogin.com" . $hash->{helper}{tenant} . "/oauth2/v2.0/token";

    my $newdata
        = "client_info=1&scope=https%3A%2F%2Fgruenbeckb2c.onmicrosoft.com%2Fiot%2Fuser_impersonation+openid+profile+offline_access&"
        . "code="
        . $hash->{helper}{code}
        . "&grant_type=authorization_code&"
        . "code_verifier="
        . $hash->{helper}{code_verifier}
        . "&redirect_uri=msal5a83cc16-ffb1-42e9-9859-9fbf07f36df8%3A%2F%2Fauth"
        . "&client_id=5a83cc16-ffb1-42e9-9859-9fbf07f36df8";

    $hash->{loglevel}        = "1";
    $newparam->{httpversion} = "1.1";
    $newparam->{data}        = $newdata;
    $newparam->{hash}        = $hash;
    $newparam->{method}      = "POST";
    $newparam->{callback}    = \&parseRefreshToken;
    main::HttpUtils_NonblockingGet($newparam);
    return;
}

sub parseRefreshToken {
    my ( $param, $err, $json ) = @_;
    my $hash   = $param->{hash};
    my $name   = $hash->{NAME};
    my $header = $param->{httpheader};

    main::Log3 $name, 5, qq($err / $json);

    my $data = safe_decode_json( $hash, $json );
    main::Log3 $name, 5, Dumper($data);

    if ( defined( $data->{error} ) ) {
        main::readingsBeginUpdate($hash);
        main::readingsBulkUpdate( $hash, "error",             $data->{error} );
        main::readingsBulkUpdate( $hash, "error_description", $data->{error_description} );
        main::readingsEndUpdate( $hash, 1 );
        return;
    }
    $hash->{helper}{accessToken}  = $data->{access_token};
    $hash->{helper}{refreshToken} = $data->{refresh_token};

    # seems like access token is valid for 14 days, refresg token for 1 hour
    main::readingsBeginUpdate($hash);
    main::readingsBulkUpdate( $hash, "accessToken",  $data->{access_token} );
    main::readingsBulkUpdate( $hash, "refreshToken", $data->{refresh_token} );
    main::readingsBulkUpdate( $hash, "not_before", strftime( "%Y-%m-%d %H:%M:%S", localtime( $data->{not_before} ) ) );
    main::readingsBulkUpdate( $hash, "expires_on", strftime( "%Y-%m-%d %H:%M:%S", localtime( $data->{expires_on} ) ) );

    main::readingsEndUpdate( $hash, 1 );

    processCmdQueue($hash);
    return;
}

sub getRefreshToken {
    my ($hash) = @_;
    my $name   = $hash->{NAME};
    my $header = {
        "Host"                     => "gruenbeckb2c.b2clogin.com",
        "x-client-SKU"             => "MSAL.iOS",
        "Accept"                   => "application/json",
        "x-client-OS"              => "12.4.1",
        "x-app-name"               => "Grünbeck myProduct",
        "x-client-CPU"             => "64",
        "x-app-ver"                => "1.0.4",
        "Accept-Language"          => "de-de",
        "client-request-id"        => "E85BBC36-160D-48B0-A93A-2694F902BF19",
        "User-Agent"               => "Gruenbeck/320 CFNetwork/978.0.7 Darwin/18.7.0",
        "x-client-Ver"             => "0.2.2",
        "x-client-DM"              => "iPhone",
        "return-client-request-id" => "true",
        "cache-control"            => "no-cache"
    };
    my $newdata
        = "client_id=5a83cc16-ffb1-42e9-9859-9fbf07f36df8&scope=https://gruenbeckb2c.onmicrosoft.com/iot/user_impersonation openid profile offline_access&"
        . "refresh_token="
        . main::ReadingsVal( $name, 'refreshToken', '' )    #$hash->{helper}{refreshToken}
        . "&client_info=1&" . "grant_type=refresh_token";
    my $param = {
        header   => $header,
        callback => \&parseRefreshToken,
        data     => $newdata,
        hash     => $hash,
        method   => "POST",
        url => "https://gruenbeckb2c.b2clogin.com" . main::ReadingsVal( $name, 'tenant', '' ) . "/oauth2/v2.0/token"
    };

    main::HttpUtils_NonblockingGet($param);
    return;
}

sub getDevices {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $header = {
        "Host"   => "prod-eu-gruenbeck-api.azurewebsites.net",
        "Accept" => "application/json, text/plain, */*",
        "User-Agent" =>
            "Mozilla/5.0 (iPhone; CPU iPhone OS 12_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Authorization"   => "Bearer " . $hash->{helper}{accessToken},
        "Accept-Language" => "de-de",
        "cache-control"   => "no-cache"
    };
    my $param = {
        header   => $header,
        url      => "https://prod-eu-gruenbeck-api.azurewebsites.net/api/devices",
        callback => \&parseDevices,
        hash     => $hash
    };
    main::HttpUtils_NonblockingGet($param);
    return;
}

sub parseDevices {
    my ( $param, $err, $json ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    main::Log3 $name, 5, qq($err / $json);
    $json = main::latin1ToUtf8($json);

    my $data = safe_decode_json( $hash, $json );
    my $dev = @$data[0];

    main::Log3 $name, 5, Dumper($data);

    if ( defined( $dev->{error} ) ) {
        main::readingsBeginUpdate($hash);
        main::readingsBulkUpdate( $hash, "error",             $dev->{error} );
        main::readingsBulkUpdate( $hash, "error_description", $dev->{error_description} );
        main::readingsEndUpdate( $hash, 1 );
        return;
    }

    main::readingsBeginUpdate($hash);

    #my @devices;

    #foreach my $dev (@data) {
    #   main::Log3 undef, 1, Dumper($dev);
    main::readingsBulkUpdate( $hash, "name", $dev->{name} );
    main::readingsBulkUpdate( $hash, "id",   $dev->{id} );

    #    push @devices, $dev->{id};
    #}
    #main::readingsBulkUpdate( $hash, "devices", join( ",", @devices ) );
    main::readingsEndUpdate( $hash, 1 );
    processCmdQueue($hash);
    return;
}

sub getMeasurements {
    my ( $hash, $type ) = @_;
    my $name = $hash->{NAME};

    my $header = {
        "Host"   => "prod-eu-gruenbeck-api.azurewebsites.net",
        "Accept" => "application/json, text/plain, */*",
        "User-Agent" =>
            "Mozilla/5.0 (iPhone; CPU iPhone OS 12_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Authorization"   => "Bearer " . $hash->{helper}{accessToken},
        "Accept-Language" => "de-de",
        "cache-control"   => "no-cache"
    };
    my $param = {
        header => $header,
        url    => "https://prod-eu-gruenbeck-api.azurewebsites.net/api/devices/"
            . main::ReadingsVal( $name, "id", "" )
            . "/measurements/"
            . $type
            . '/?api-version=2019-08-09/',
        hash => $hash
    };

    my ( $err, $json ) = main::HttpUtils_BlockingGet($param);
    main::Log3 $name, 5, qq($err / $json);
    $json = main::latin1ToUtf8($json);

    #my $data = safe_decode_json( $hash, $json );
    my $cdata = safe_decode_json( $hash, $json );
    my $data = @$cdata[0];

    main::Log3 $name, 5, Dumper($data);

    if ( defined( $data->{error} ) ) {
        main::readingsBeginUpdate($hash);
        main::readingsBulkUpdate( $hash, "error",             $data->{error} );
        main::readingsBulkUpdate( $hash, "error_description", $data->{error_description} );
        main::readingsEndUpdate( $hash, 1 );
        return $data->{error_description};
    }
    my $ret;
    foreach my $d (@$cdata) {
        $ret .= '<div>' . $d->{date} . ' : ' . $d->{value} . '</div>';
    }
    return $ret;
}

sub getInfo {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $header = {
        "Host"   => "prod-eu-gruenbeck-api.azurewebsites.net",
        "Accept" => "application/json, text/plain, */*",
        "User-Agent" =>
            "Mozilla/5.0 (iPhone; CPU iPhone OS 12_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Authorization"   => "Bearer " . main::ReadingsVal( $name, 'accessToken', undef ),
        "Accept-Language" => "de-de",
        "cache-control"   => "no-cache"
    };
    my $param = {
        header => $header,
        url    => "https://prod-eu-gruenbeck-api.azurewebsites.net/api/devices/" . main::ReadingsVal( $name, "id", "" ),
        callback => \&parseInfo,
        hash     => $hash
    };
    main::HttpUtils_NonblockingGet($param);
    return;
}

sub parseInfo {
    my ( $param, $err, $json ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    main::Log3 $name, 5, qq($err / $json);
    $json = main::latin1ToUtf8($json);

    my @cdata = safe_decode_json( $hash, $json );
    my $data = $cdata[0];
    main::Log3 $name, 5, Dumper($data);

    if ( defined( $data->{error} ) ) {
        main::readingsBeginUpdate($hash);
        main::readingsBulkUpdate( $hash, "error",             $data->{error} );
        main::readingsBulkUpdate( $hash, "error_description", $data->{error_description} );
        main::readingsEndUpdate( $hash, 1 );
        return;
    }

    main::readingsBeginUpdate($hash);
    my %info = %{$data};
    my $i    = 0;
    foreach my $key ( keys %info ) {
        if ( ref( $info{$key} ) eq "ARRAY" ) {
            if ( $key eq "water" || $key eq "salt" ) {
                $i = 0;
                foreach my $dp ( @{ $info{$key} } ) {
                    main::readingsBulkUpdate( $hash, $key . "_" . $i . "_date",  $dp->{date} );
                    main::readingsBulkUpdate( $hash, $key . "_" . $i . "_value", $dp->{value} );
                    $i++;
                }
            }
        }
        else {
            main::readingsBulkUpdate( $hash, $key, $info{$key} );
        }
    }
    main::readingsEndUpdate( $hash, 1 );
    processCmdQueue($hash);
    return;
}

sub getParam {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $header = {
        "Host"   => "prod-eu-gruenbeck-api.azurewebsites.net",
        "Accept" => "application/json, text/plain, */*",
        "User-Agent" =>
            "Mozilla/5.0 (iPhone; CPU iPhone OS 12_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Authorization"   => "Bearer " . $hash->{helper}{accessToken},
        "Accept-Language" => "de-de",
        "cache-control"   => "no-cache"
    };
    my $param = {
        header => $header,
        url    => "https://prod-eu-gruenbeck-api.azurewebsites.net/api/devices/"
            . main::ReadingsVal( $name, "id", "" )
            . '/parameters?api-version=2019-08-09',
        callback => \&parseParam,
        hash     => $hash
    };
    main::HttpUtils_NonblockingGet($param);
    return;
}

sub parseParam {
    my ( $param, $err, $json ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    main::Log3 $name, 5, qq($err / $json);
    $json = main::latin1ToUtf8($json);

    my $data = safe_decode_json( $hash, $json );

    #my $data = @$cdata[0];
    main::Log3 $name, 5, Dumper($data);

    if ( defined( $data->{error} ) ) {
        main::readingsBeginUpdate($hash);
        main::readingsBulkUpdate( $hash, "error",             $data->{error} );
        main::readingsBulkUpdate( $hash, "error_description", $data->{error_description} );
        main::readingsEndUpdate( $hash, 1 );
        return;
    }

    main::readingsBeginUpdate($hash);
    my %info = %{$data};
    my $i    = 0;
    foreach my $key ( keys %info ) {
        if ( ref( $info{$key} ) eq "ARRAY" ) {

            #we'll have to check that
        }
        else {
            main::readingsBulkUpdate( $hash, $key, $info{$key} );
        }
    }
    main::readingsEndUpdate( $hash, 1 );
    processCmdQueue($hash);
    return;
}

sub negotiate {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $header = {
        "Content-Type" => "text/plain;charset=UTF-8",
        "Origin"       => "file://",
        "Accept"       => "*/*",
        "User-Agent" =>
            "Mozilla/5.0 (iPhone; CPU iPhone OS 12_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Authorization"   => "Bearer " . $hash->{helper}{accessToken},
        "Accept-Language" => "de-de",
        "cache-control"   => "no-cache"
    };
    my $param = {
        header   => $header,
        url      => "https://prod-eu-gruenbeck-api.azurewebsites.net/api/realtime/negotiate",
        callback => \&parseNegotiate,
        hash     => $hash
    };
    main::HttpUtils_NonblockingGet($param);
    return;
}

sub parseNegotiate {
    my ( $param, $err, $json ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    main::Log3 $name, 5, qq($err / $json);
    my $data = safe_decode_json( $hash, $json );
    main::Log3 $name, 5, Dumper($data);

    if ( defined( $data->{error} ) ) {
        main::readingsBeginUpdate($hash);
        main::readingsBulkUpdate( $hash, "error",             $data->{error} );
        main::readingsBulkUpdate( $hash, "error_description", $data->{error_description} );
        main::readingsEndUpdate( $hash, 1 );
        return;
    }

    $hash->{helper}{wsAccessToken} = $data->{accessToken};
    $hash->{helper}{wsUrl}         = $data->{url};

    my $newheader = {
        "Content-Type" => "text/plain;charset=UTF-8",
        "Origin"       => "file://",
        "Accept"       => "*/*",
        "User-Agent" =>
            "   Mozilla/5.0 (iPhone; CPU iPhone OS 13_3_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Authorization"    => "Bearer " . $hash->{helper}{wsAccessToken},
        "Accept-Language"  => "de-de",
        "X-Requested-With" => "XMLHttpRequest",
        "Content-Length"   => 0
    };
    my $newparam = {
        header => $newheader,
        url    => "https://prod-eu-gruenbeck-signalr.service.signalr.net/client/negotiate?hub=gruenbeck"
        ,    #$hash->{helper}{wsUrl},
        callback => \&parseWebsocketId,
        hash     => $hash,
        method   => "POST",
        data     => ""
    };
    main::HttpUtils_NonblockingGet($newparam);

    #processCmdQueue($hash);
    return;

}

sub parseWebsocketId {
    my ( $param, $err, $json ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    main::Log3 $name, 5, qq($err / $json);
    my $data = safe_decode_json( $hash, $json );
    main::Log3 $name, 5, Dumper($data);

    if ( defined( $data->{error} ) ) {
        main::readingsBeginUpdate($hash);
        main::readingsBulkUpdate( $hash, "error",             $data->{error} );
        main::readingsBulkUpdate( $hash, "error_description", $data->{error_description} );
        main::readingsEndUpdate( $hash, 1 );
        return;
    }

    $hash->{helper}{wsId} = $data->{connectionId};
    return unless $data->{connectionId};

    my $url
        = "wss://prod-eu-gruenbeck-signalr.service.signalr.net/client/?hub=gruenbeck&id="
        . $hash->{helper}{wsId}
        . "&access_token="
        . $hash->{helper}{wsAccessToken};
    realtime( $hash, "enter" );
    wsConnect( $hash, $url );
    realtime( $hash, "refresh" );
    processCmdQueue($hash);
    return;
}

sub realtime {

    my ( $hash, $type ) = @_;
    my $name = $hash->{NAME};

    my $header = {
        "Content-Length" => 0,
        "Origin"         => "file://",
        "Accept"         => "*/*",
        "User-Agent" =>
            "Mozilla/5.0 (iPhone; CPU iPhone OS 12_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Authorization"   => "Bearer " . $hash->{helper}{accessToken},
        "Accept-Language" => "de-de",
        "cache-control"   => "no-cache"
    };
    my $param = {
        header => $header,
        url    => "https://prod-eu-gruenbeck-api.azurewebsites.net/api/devices/"
            . main::ReadingsVal( $name, "id", "" )
            . "/realtime/$type?api-version=2019-08-09",
        callback => \&parseRealtime,
        hash     => $hash,
        method   => "POST"
    };

    main::HttpUtils_NonblockingGet($param);
    return;

}

sub parseRealtime {
    my ( $param, $err, $json ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    return;
}

sub getCookies {
    my ( $hash, $header ) = @_;
    my $name = $hash->{NAME};
    delete $hash->{HTTPCookieHash};
    foreach my $cookie ( $header =~ m/set-cookie: ?(.*)/gi ) {
        $cookie =~ /([^,; ]+)=([^,;\s\v]+)[;,\s\v]*([^\v]*)/;

        #main::Log3 $name, 1, "$name: GetCookies parsed Cookie: $1 Wert $2 Rest $3";
        my $name  = $1;
        my $value = $2;
        my $rest  = ( $3 ? $3 : "" );
        my $path  = "";
        if ( $rest =~ /path=([^;,]+)/ ) {
            $path = $1;
        }
        my $key = $name . ';' . $path;
        $hash->{HTTPCookieHash}{$key}{Name}    = $name;
        $hash->{HTTPCookieHash}{$key}{Value}   = $value;
        $hash->{HTTPCookieHash}{$key}{Options} = $rest;
        $hash->{HTTPCookieHash}{$key}{Path}    = $path;
    }
}

sub processCmdQueue {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    return if ( !defined( $hash->{helper}{cmdQueue} ) );
    my $cmd = shift @{ $hash->{helper}{cmdQueue} };
    return unless ref($cmd) eq "CODE";
    my $cv = main::svref_2object($cmd);
    my $gv = $cv->GV;
    main::Log3 $name, 4, "[$name] Processing Queue: " . $gv->NAME;
    $cmd->($hash);
}

sub safe_decode_json {
    my ( $hash, $data ) = @_;
    my $name = $hash->{NAME};

    my $json = undef;
    eval {
        $json = decode_json($data);
        1;
    } or do {
        my $error = $@ || 'Unknown failure';
        main::Log3 $name, 1, "[$name] - Received invalid JSON: $error";

    };
    return $json;
}

# based on https://greg-kennedy.com/wordpress/2019/03/11/writing-a-websocket-client-in-perl-5/
sub wsConnect {
    my ( $hash, $url ) = @_;
    my $name = $hash->{NAME};

    # Protocol::WebSocket takes a full URL, but IO::Socket::* uses only a host
    #  and port.  This regex section retrieves host/port from URL.
    my ( $proto, $host, $port, $path );
    if ( $url =~ m/^(?:(?<proto>ws|wss):\/\/)?(?<host>[^\/:]+)(?::(?<port>\d+))?(?<path>\/.*)?$/ ) {
        $host = $+{host};
        $path = $+{path};

        if ( defined $+{proto} && defined $+{port} ) {
            $proto = $+{proto};
            $port  = $+{port};
        }
        elsif ( defined $+{port} ) {
            $port = $+{port};
            if   ( $port == 443 ) { $proto = 'wss' }
            else                  { $proto = 'ws' }
        }
        elsif ( defined $+{proto} ) {
            $proto = $+{proto};
            if   ( $proto eq 'wss' ) { $port = 443 }
            else                     { $port = 80 }
        }
        else {
            $proto = 'ws';
            $port  = 80;
        }
    }
    else {
        main::Log3 $name, 1, "[$name] Failed to parse Host/Port from URL.";
    }

    main::Log3 $name, 4, "[$name] Attempting to open SSL socket to $proto://$host:$port...";

    # create a connecting socket
    #  SSL_startHandshake is dependent on the protocol: this lets us use one socket
    #  to work with either SSL or non-SSL sockets.
    # my $tcp_socket = IO::Socket::SSL->new(
    #     PeerAddr                   => $host,
    #     PeerPort                   => "$proto($port)",
    #     Proto                      => 'tcp',
    #     SSL_startHandshake         => ( $proto eq 'wss' ? 1 : 0 ),
    #     Blocking                   => 1
    # ) or main::Log3 $name, 1, "[$name] Failed to connect to socket: $@";

    $hash->{DeviceName} = $host . $port;
    $hash->{helper}{url} = $url;
    main::DevIo_CloseDev($hash) if ( main::DevIo_IsOpen($hash) );
    main::DevIo_OpenDev( $hash, 1, "FHEM::SoftliqCloud::wsHandshake", "FHEM::SoftliqCloud::wsFail" );

    main::Log3 $name, 1, "[$name] Opening Websocket";
    return;
}

sub wsHandshake {
    my $hash       = shift;
    my $name       = $hash->{NAME};
    my $tcp_socket = $hash->{TCPDev};
    my $url        = $hash->{helper}{url} = $url;

    # create a websocket protocol handler
    #  this doesn't actually "do" anything with the socket:
    #  it just encodes / decode WebSocket messages.  We have to send them ourselves.
    main::Log3 $name, 4, "[$name] Trying to create Protocol::WebSocket::Client handler for $url...";
    my $client = Protocol::WebSocket::Client->new(
        url     => $url,
        version => "13",
    );

    # Set up the various methods for the WS Protocol handler
    #  On Write: take the buffer (WebSocket packet) and send it on the socket.
    $client->on(
        write => sub {
            my $client = shift;
            my ($buf) = @_;

            syswrite $tcp_socket, $buf;
        }
    );

    # On Connect: this is what happens after the handshake succeeds, and we
    #  are "connected" to the service.
    $client->on(
        connect => sub {
            my $client = shift;

            # You may wish to set a global variable here (our $isConnected), or
            #  just put your logic as I did here.  Or nothing at all :)
            main::Log3 $name, 4, "[$name] Successfully connected to service!";
            $client->write('{"protocol":"json","version":1}');
        }
    );

    # On Error, print to console.  This can happen if the handshake
    #  fails for whatever reason.
    $client->on(
        error => sub {
            my $client = shift;
            my ($buf) = @_;

            main::Log3 $name, 1, "[$name] ERROR ON WEBSOCKET: $buf";
            $tcp_socket->close;
            exit;
        }
    );

    # On Read: This method is called whenever a complete WebSocket "frame"
    #  is successfully parsed.
    # We will simply print the decoded packet to screen.  Depending on the service,
    #  you may e.g. call decode_json($buf) or whatever.
    $client->on(
        read => sub {
            my $client = shift;
            my ($buf) = @_;
            $buf =~ s///;
            main::Log3 $name, 3, "[$name] Received from socket: '$buf'";
            my $json = safe_decode_json( $hash, $buf );
            if ( $json->{type} && $json->{type} ne '6' ) {

                #main::Log3 $name, 1, "[$name] $client Received from socket: " . Dumper($json);
                main::readingsBeginUpdate($hash);
                my @args = @{ $json->{arguments} };
                my %info = %{ $args[0] };
                my $i    = 0;
                foreach my $key ( keys %info ) {
                    main::readingsBulkUpdate( $hash, $key, $info{$key} );
                }
                main::readingsEndUpdate( $hash, 1 );

            }
            return;
        }
    );

    # Now that we've set all that up, call connect on $client.
    #  This causes the Protocol object to create a handshake and write it
    #  (using the on_write method we specified - which includes sysread $tcp_socket)
    main::Log3 $name, 4, "[$name] Calling connect on client...";
    $client->connect;

    # read until handshake is complete.
    while ( !$client->{hs}->is_done ) {
        my $recv_data;

        my $bytes_read = sysread $tcp_socket, $recv_data, 16384;

        if    ( !defined $bytes_read ) { main::Log3 $name, 1, "[$name] sysread on tcp_socket failed: $!" }
        elsif ( $bytes_read == 0 )     { main::Log3 $name, 1, "[$name] Connection terminated." }

        $client->read($recv_data);
    }

    # Create a Socket Set for Select.
    #  We can then test this in a loop to see if we should call read.
    my $set = IO::Select->new($tcp_socket);

    $hash->{helper}{wsSet}    = $set;
    $hash->{helper}{wsClient} = $client;
    my $next = int( main::gettimeofday() ) + 1;
    $hash->{helper}{wsCount} = 0;
    main::InternalTimer( $next, 'FHEM::SoftliqCloud::wsRead', $hash, 0 );
    return;
}

sub wsRead {
    my ($hash) = @_;
    my $name   = $hash->{NAME};
    my $set    = $hash->{helper}{wsSet};
    my $client = $hash->{helper}{wsClient};

    # call select and see who's got data
    my ($ready) = IO::Select->select($set);

    foreach my $ready_socket (@$ready) {

        # read data from ready socket
        my $recv_data;
        my $bytes_read = sysread $ready_socket, $recv_data, 16384;

        # Input arrived from remote WebSocket!
        if ( !defined $bytes_read ) { main::Log3 $name, 1, "[$name] Error reading from tcp_socket: $!" }
        elsif ( $bytes_read == 0 ) {

            # Remote socket closed
            main::Log3 $name, 1, "[$name] Connection terminated by remote.";
            return;
        }
        else {
            # unpack response - this triggers any handler if a complete packet is read.
            $client->read($recv_data);

            #last;
        }
    }
    my $next = int( main::gettimeofday() ) + 1;
    $hash->{helper}{wsCount}++;
    if ( $hash->{helper}{wsCount} > 50 ) {
        $client->disconnect;
        delete $hash->{helper}{wsSet};
        delete $hash->{helper}{wsClient};
        return;
    }
    main::InternalTimer( $next, 'FHEM::SoftliqCloud::wsRead', $hash, 0 );

}

sub wsFail {
    my ( $hash, $error ) = @_;
    my $name = $hash->{NAME};

    # create a log emtry with the error message
    main::Log3 $name, 1, "MY_MODULE ($name) - error while connecting: $error";

    return;
}

sub Ready {
    my ($hash) = @_;

    # try to reopen the connection in case the connection is lost
    return main::DevIo_OpenDev( $hash, 1, "FHEM::SoftliqCloud::wsHandshake", "FHEM::SoftliqCloud::wsFail" );
}

sub wsReadDevIo {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    # read the available data
    my $buf = main::DevIo_SimpleRead($hash);

    # stop processing if no data is available (device disconnected)
    return if ( !defined($buf) );

    main::Log3 $name, 1, "MY_MODULE ($name) - received: $buf";

    #
    # do something with $buf, e.g. generate readings, send answers via DevIo_SimpleWrite(), ...
    #

}

1;
