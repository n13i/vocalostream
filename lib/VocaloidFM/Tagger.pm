# edit Ogg comments using vorbiscomment

package VocaloidFM::Tagger;

use strict;
use warnings;
use utf8;
use Carp;
use version; our $VERSION = qv("0.0.1");

use FindBin qw($Bin);
use FindBin::libs;

use Encode;
use IPC::Run qw(run timeout);

use VocaloidFM;

# static
sub set_comments
{
    my $filename = shift || return undef;
    my $args = shift || return undef;

    my $conf = VocaloidFM::get_config;

    my ($in, $out, $err);

    if(!-e $filename)
    {
        return undef;
    }

    # 現在のコメントを取得
    run [$conf->{cmds}->{vorbiscomment},
         '--raw',
         $filename],
        '>', \$out, '2>', \$err,
        timeout(10) or die "$?";

    my %comments = %{$args};
    foreach(split /\n/, decode('utf8', $out))
    {
        if(/^([^=]+)=(.+)$/)
        {
            #printf "OLD> %s: %s\n", $1, $2;
            if(!defined(${$args}{$1}))
            {
                $comments{$1} = $2;
            }
        }
    }

    $in = '';
    foreach(keys(%comments))
    {
        next if(!defined($comments{$_}) || $comments{$_} eq '');
        #printf "NEW> %s: %s\n", $_, $comments{$_};
        $in .= sprintf "%s=%s\n", $_, $comments{$_};
    }

    $in = encode('utf8', $in);

    # 更新したコメントを書き込む
    run [$conf->{cmds}->{vorbiscomment},
         '--raw',
         '--write',
         $filename],
        '<', \$in, '>', \$out, '2>', \$err,
        timeout(10) or die "$?";
}

1;
__END__

