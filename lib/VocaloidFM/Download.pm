# wrapper of WWW::NicoVideo::Download and misc

package VocaloidFM::Download;

use strict;
use warnings;
use utf8;
use Carp;
use version; our $VERSION = qv("0.0.1");

use FindBin qw($Bin);
use FindBin::libs;

use HTTP::Cookies;
use WWW::NicoVideo::Download;
use XML::Simple;
use HTML::Entities;

use VocaloidFM;

sub new
{
    my $class = shift;
    my $self = {
        nicovideo => undef,
        cookie_jar => undef,
    };

    my $conf = VocaloidFM::get_config;

    $self->{nicovideo} = WWW::NicoVideo::Download->new(
        email => $conf->{nicovideo}->{email},
        password => $conf->{nicovideo}->{password},
    );
    $self->{cookie_jar} = HTTP::Cookies->new(
        file => $conf->{dirs}->{data} . '/cookies.txt',
        autosave => 1,
    );
    $self->{nicovideo}->user_agent->cookie_jar($self->{cookie_jar});
    $self->{nicovideo}->user_agent->timeout(30);

    return bless $self, $class;
}

sub download
{
    my $self = shift;
    my $video_id = shift;
    my $file = shift;

    $self->{nicovideo}->download($video_id, $file);
}

sub get_username
{
    my $self = shift;
    my $video_id = shift || return undef;

    my $username = undef;

    if(!($video_id =~ /(\d+)/))
    {
        return undef;
    }

    my $id = $1;
    my $res = $self->{nicovideo}->user_agent->get(
        'http://www.smilevideo.jp/allegation/allegation/' . $id . '/'
    );
    if($res->is_error)
    {
        return undef;
    }

    if($res->decoded_content =~ m{
        <p\sclass="TXT12"><strong>([^<]+)</strong>\sが投稿した
    }sx)
    {
        $username = decode_entities($1);
    }

    return $username;
}

sub get_thumbinfo
{
    my $self = shift;
    my $video_id = shift || undef;

    my $res = $self->{nicovideo}->user_agent->get(
        'http://www.nicovideo.jp/api/getthumbinfo/' . $video_id
    );
    if($res->is_error)
    {
        return undef;
    }

    my $xs = XML::Simple->new;
    my $x = $xs->XMLin($res->decoded_content);

    return $x;
}

# static
sub get_tags
{
    my $tags = [];

    my $x = shift || return undef;
    my $thumb_tags = $x->{thumb}->{tags};

    if(ref($thumb_tags) eq 'ARRAY')
    {
        foreach my $d (@{$thumb_tags})
        {
            push(@{$tags}, &_get_tags2($d));
        }
    }
    else
    {
        # domain が存在しない場合
        push(@{$tags}, &_get_tags2($thumb_tags));
    }

    return $tags;
}

# static
sub _get_tags2
{
    my @tags = ();
    my $t = shift || return @tags;

    my $domain = $t->{domain} || 'jp';

    if(ref($t->{tag}) eq 'ARRAY')
    {
        # タグが複数の場合
        foreach(@{$t->{tag}})
        {
            my $tag = &_get_tags3($_);
            if(defined($tag))
            {
                $tag->{domain} = $domain;
                push(@tags, $tag);
            }
        }
    }
    else
    {
        # タグが単数の場合
        my $tag = &_get_tags3($t->{tag});
        if(defined($tag))
        {
            $tag->{domain} = $domain;
            push(@tags, $tag);
        }
    }

    return @tags;
}

# static
sub _get_tags3
{
    my $t = shift || return undef;
    my $tag;
    if(ref($t) eq 'HASH')
    {
        $tag = {
            content => $t->{content},
            lock => $t->{lock},
        };
    }
    else
    {
        $tag = {
            content => $t,
            lock => 0,
        };
    }

    $tag->{content} = decode_entities($tag->{content});

    return $tag;
}

1;
__END__

