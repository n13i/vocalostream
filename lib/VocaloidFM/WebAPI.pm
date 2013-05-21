package VocaloidFM::WebAPI;

use strict;
use warnings;
use utf8;
use Carp;
use version; our $VERSION = qv("0.0.1");

use FindBin qw($Bin);
use FindBin::libs;

use LWP::UserAgent;
use JSON;
use Encode;

use VocaloidFM;

sub new
{
    my $class = shift;
    my $self = {
        lwp => undef,
        ep => undef,
        actions => undef,
    };

    my $conf = VocaloidFM::get_config;

    $self->{ep} = $conf->{vocast_api}->{endpoint};
    $self->{actions} = $conf->{vocast_api}->{actions};

    $self->{lwp} = LWP::UserAgent->new;
    $self->{lwp}->timeout(30);

    return bless $self, $class;
}

sub update_currentsong
{
    my $self = shift;
    my $args = shift;

    my %postdata = ();
    foreach my $key (keys %{$args})
    {
        $postdata{$key} = encode('utf8', $args->{$key});
    }

    my $req = HTTP::Request->new(
        POST => $self->{ep} . $self->{actions}->{update_currentsong}
    );
    $req->header('Content-Type' => 'application/json; charset=utf8');
    $req->content(JSON->new->encode(\%postdata));
    my $res = $self->{lwp}->request($req);

    return $res;
}

1;
__END__

