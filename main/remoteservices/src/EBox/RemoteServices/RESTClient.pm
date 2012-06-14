# Copyright (C) 2012 eBox Technologies S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

package EBox::RemoteServices::RESTClient;

# Class: EBox::RemoteServices::RESTClient
#
#   Zentyal Cloud REST client. It provides a common
#   interface to access Zentyal Cloud services
#

use warnings;
use strict;

use EBox;
use EBox::Config;
use EBox::Gettext;
use EBox::Exceptions::Internal;
use EBox::Exceptions::MissingArgument;
use EBox::RemoteServices::Configuration;
use EBox::RemoteServices::RESTResult;
use Error qw(:try);
use File::Temp;
use HTTP::Status qw(HTTP_UNAUTHORIZED);
use IO::Socket::SSL;
use JSON::XS;
use LWP::UserAgent;
use Time::HiRes;
use URI;

use constant SUBS_WIZARD_URL => '/Wizard?page=RemoteServices/Wizard/Subscription';
# use constant BASE_URL => 'http://192.168.56.1:8000/'; #FIXME

# Method: new
#
#   Zentyal Cloud REST client. It provides a common
#   interface to access Zentyal Cloud services
#
# Parameters:
#
#   credentials - Hash ref containing the credentials required
#                 to access the given server
#                 It must contain the following keys:
#
#                    realm - String the realm
#                    username - String the username
#                    password - String the password
#
#                 (Optional)
#
#  - Named parameters
#
sub new {
    my ($class, %params) = @_;

    my $self = bless({credentials => $params{credentials}}, $class);

    if ( exists $self->{credentials} and (not $self->{credentials}->{realm}) ) {
        $self->{credentials}->{realm} = 'Zentyal Cloud API';
    }
    # Get the server from conf
    my $key = 'rs_api';
    $self->{server} = 'https://' . EBox::Config::configkey($key);
    # $self->{server} = BASE_URL; # FIXME: To remove

    return $self;
}

# Method: GET
#
#   Perform a GET operation
#
# Parameters:
#
#   path - relative path for the query (ie. /subscription)
#   query - hash ref containing query parameters
#            (Optional)
#
# Returns:
#
#   hash ref with the reply from the server
#
sub GET {
    my ($self, $path, $query) = @_;
    return $self->request('GET', $path, $query);
}

# Method: PUT
#
#   Perform a PUT operation
#
# Parameters:
#
#   path - relative path for the query (ie. /subscription)
#   query - hash ref containing query parameters (Optional)
#
# Returns:
#
#   hash ref with the reply from the server
#
sub PUT {
    my ($self, $path, $query) = @_;
    return $self->request('PUT', $path, $query);
}

# Method: POST
#
#   Perform a POST operation
#
# Parameters:
#
#   path - relative path for the query (ie. /subscription)
#   query - hash ref containing query parameters (Optional)
#
# Returns:
#
#   hash ref with the reply from the server
#
sub POST {
    my ($self, $path, $query) = @_;
    return $self->request('POST', $path, $query);
}

# Method: DELETE
#
#   Perform a DELETE operation
#
# Parameters:
#
#   path - relative path for the query (ie. /subscription)
#   query - hash ref containing query parameters (Optional)
#
# Returns:
#
#   hash ref with the reply from the server
#
sub DELETE {
    my ($self, $path, $query) = @_;
    return $self->request('DELETE', $path, $query);
}


sub request {
    my ($self, $method, $path, $query) = @_;

    throw EBox::Exceptions::MissingArgument('method') unless (defined($method));
    throw EBox::Exceptions::MissingArgument('path') unless (defined($path));

    # build UA
    my $ua = LWP::UserAgent->new;
    my $version = EBox::Config::version();
    $ua->agent("ZentyalServer $version");
    $ua->ssl_opts('verify_hostname' => EBox::Config::boolean('rs_verify_servers'));

    my $req = HTTP::Request->new( $method => $self->{server} . $path );
    if ( exists $self->{credentials} ) {
        $req->authorization_basic($self->{credentials}->{username}, $self->{credentials}->{password});
    }

    #build headers
    if ($query) {
        if ( ref($query) eq 'ARRAY' ) {
            throw EBox::Exceptions::Internal('Cannot send array ref as query when using GET method')
              if ($method eq 'GET');
            # Send data in JSON if the query is an array of elements
            my $encoder = new JSON::XS()->utf8()->allow_blessed(1)->convert_blessed(1);
            my $data = $encoder->encode($query);
            $req->content_type('application/json');
            $req->content($data);
            $req->header('Content-Length', length($data));
        } else {
            my $uri = URI->new();
            $uri->query_form($query);
            if ( $method eq 'GET' ) {
                $req->uri( $self->{server} . $path . '?' . $uri->query() );
                $req->header('Content-Length', 0);
            } else {
                my $data = $uri->query();
                $req->content_type('application/x-www-form-urlencoded');
                $req->content($data);
                $req->header('Content-Length', length($data));
            }
        }
    } else{
        $req->header('Content-Length', 0);
    }

    my $res = $ua->request($req);

    if ($res->is_success) {
        return new EBox::RemoteServices::RESTResult($res);
    }
    else {
        $self->{last_error} = new EBox::RemoteServices::RESTResult($res);
        if ($res->code() == HTTP_UNAUTHORIZED) {
            throw EBox::Exceptions::External($self->_invalidCredentialsMsg());
        }
        $self->_storeInJournal($method, $path, $query, $res);
        throw EBox::Exceptions::Internal($res->code() . " : " . $res->content());
    }
}

# Method: last_error
#
#   Return last error result after a failed request
#
sub last_error
{
    my ($self) = @_;

    return $self->{last_error};
}


# Function: _invalidCredentialsMsg
#
#     Return the invalid credentials message
#
# Returns:
#
#     String - the message
#
sub _invalidCredentialsMsg
{
    my $cpURL = EBox::Config::configkey('ebox_services_nameserver');
    $cpURL =~ s:^.*?\.::;
    my $forgottenURL = "https://www.${cpURL}/reset/";
    return __x('User/email address and password do not match. Did you forget your password? '
               . 'You can reset it {ohp}here{closehref}. '
               . 'If you need a new account you can subscribe {openhref}here{closehref}.'
               , openhref  => '<a href="'. SUBS_WIZARD_URL . '" target="_blank">',
               ohp       => '<a href="' . $forgottenURL . '" target="_blank">',
               closehref => '</a>');

}

# Store the op in the journal
sub _storeInJournal
{
    my ($self, $method, $path, $query, $res) = @_;

    my $journalDir = EBox::RemoteServices::Configuration::JournalOpsDirPath();
    # Store only in the journal if the server is subscribed
    return unless (defined($journalDir));
    my $time = join('', Time::HiRes::gettimeofday());
    my $tmpFile = new File::Temp(TEMPLATE => "$time-XXXX", DIR => $journalDir,
                                 UNLINK => 0);

    my $encoder = new JSON::XS()->utf8()->allow_blessed(1)->convert_blessed(1);
    my $action = { 'method' => $method,
                   'path'   => $path,
                   'query'  => $query,
                   'res_code' => $res->code(),
                   'res_content' => $res->decoded_content() };
    print $tmpFile $encoder->encode($action);
}

1;