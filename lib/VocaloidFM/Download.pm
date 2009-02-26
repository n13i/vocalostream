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

sub check_status
{
    my $self = shift;
    my $video_id = shift;

    my $conf = VocaloidFM::get_config;

    foreach(@{$conf->{nglist}})
    {
        if($video_id =~ /^$_$/i)
        {
            return {
                code => -1,
                text => 'in blacklist',
                tags => undef,
                thumbinfo => undef,
            };
        }
    }

    my $x = $self->get_thumbinfo($video_id);
    if(!defined($x))
    {
        return {
            code => -2,
            text => 'getthumbinfo failed',
            tags => undef,
            thumbinfo => undef,
        };
    }
    if($x->{status} ne 'ok')
    {
        return {
            code => -3,
            text => 'deleted',
            tags => undef,
            thumbinfo => $x,
        };
    }

    $x->{thumb}->{title} = decode_entities($x->{thumb}->{title});
    #printf "%s\n", $x->{thumb}->{title};
 
    if($x->{thumb}->{embeddable} == 0)
    {
        return {
            code => -4,
            text => 'not embeddable',
            tags => undef,
            thumbinfo => $x,
        };
    }

    # チェックするタグの情報をセット
    my @tags_checked = ();
    foreach(@{$conf->{tagcheck}->{required}})
    {
        #printf "REQUIRED: %s\n", $_;
        push(@tags_checked, { type => 1, expr => $_, found => 0 });
    }
    foreach(@{$conf->{tagcheck}->{ng}})
    {
        #printf "NG: %s\n", $_;
        push(@tags_checked, { type => -1, expr => $_, found => 0 });
    }

    # タグを取得してチェック
    my $tags = VocaloidFM::Download::get_tags($x);
    foreach my $tag (@{$tags})
    {
        my $t = $tag->{content};
        $t =~ tr/Ａ-Ｚａ-ｚ/A-Za-z/;
        foreach(@tags_checked)
        {
            my $expr = $_->{expr};
            if($t =~ /$expr/i)
            {
                $_->{found} = 1;
            }
        }
    }

    my $tags_ok = 1;
    foreach(@tags_checked)
    {
        if(($_->{type} == 1 && $_->{found} == 0) ||
           ($_->{type} == -1 && $_->{found} == 1))
        {
            # 必須タグが見つからない or NG タグが見つかった
            $tags_ok = 0;
            last;
        }
    }

    # ホワイトリストにあるものは許可
    foreach(@{$conf->{whitelist}})
    {
        if($video_id =~ /^$_$/i)
        {
            $tags_ok = 1;
        }
    }

    if($tags_ok == 0)
    {
        return {
            code => -5,
            text => 'tagcheck failed',
            tags => $tags,
            thumbinfo => $x,
        };
    }

    return {
        code => 1,
        text => 'ok',
        tags => $tags,
        thumbinfo => $x,
    };
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

sub get_pname
{
    my $self = shift;
    my $username = shift || return undef;
    my $tags = shift || return undef;

    my $conf = VocaloidFM::get_config;

    # P 名テーブルを用意
    open FH, '<:encoding(utf8)', $conf->{pname} or return undef;
    my $pname_table = YAML::Load(join('', <FH>));
    close FH;

    if(!defined(${$pname_table}{$username}))
    {
        return undef;
    }

    my $ptag_cand = ${$pname_table}{$username};
    my @ptags = ();
    if(ref($ptag_cand) eq 'ARRAY')
    {
        @ptags = @{$ptag_cand};
    }
    else
    {
        push(@ptags, $ptag_cand);
    }

    my $pname = undef;
    foreach my $p (@ptags)
    {
        my $p_norm = $p;
        $p_norm =~ tr/Ａ-Ｚａ-ｚ/A-Za-z/;

        foreach(@{$tags})
        {
            my $t = $_->{content};
            $t =~ tr/Ａ-Ｚａ-ｚ/A-Za-z/;

            if(lc($t) eq lc($p_norm))
            {
                $pname = $p;
                last;
            }
        }
    }

    return $pname;
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

