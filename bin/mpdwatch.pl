#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use FindBin::libs;

use DBD::SQLite;
use Audio::MPD;
use Net::Twitter::Lite;
use YAML;
use Encode;
use DateTime;

use VocaloidFM;
use VocaloidFM::Download;
use VocaloidFM::Tagger;

binmode STDOUT, ':encoding(utf8)';

my $logdomain = 'MPDWatcher';

my $conf = load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{db},
    '', '', {sqlite_unicode => 1}
);

my $mpd = Audio::MPD->new(
    hostname => $conf->{mpd}->{host},
    port => $conf->{mpd}->{port},
);

&init_mpd;

my $twit = Net::Twitter::Lite->new(
    api_url => $conf->{twitter}->{api_url},
    upload_url => $conf->{twitter}->{upload_url},
    consumer_key => $conf->{twitter}->{consumer_key},
    consumer_secret => $conf->{twitter}->{consumer_secret},
);
$twit->access_token($conf->{twitter}->{access_token});
$twit->access_token_secret($conf->{twitter}->{access_token_secret});

my $current_id = -1;
if(defined(my $song = $mpd->song))
{
    $current_id = $song->id;
}
my $request_info = undef;

my $mainloop = 1;

$SIG{HUP} = \&stop;
$SIG{KILL} = \&stop;
$SIG{TERM} = \&stop;
$SIG{INT} = \&stop;

my $check_interval = $conf->{playlist}->{check_interval};
my $add_interval = $conf->{playlist}->{add_interval};

my $next_addtime = 0; #time + $add_interval;

logger $logdomain, "%s\n",
    '$Id$';

while($mainloop)
{
    my $status = $mpd->status;

    # リクエスト曲追加処理
    # 1 曲再生につき 1 曲だけ追加するようにする
    # 残り時間が少ない場合には追加しないように
    if(!defined($request_info) && $status->time->seconds_left >= 30)
    {
        $request_info = &add_playlist({request_mode => 1});
        if(defined($request_info))
        {
            logger $logdomain, "request from @%s: queueing done.\n",
                $request_info->{user_screen_name};
        }
    }

    # リクエスト曲以外の追加処理
    if(time >= $next_addtime)
    {
        &add_playlist({request_mode => 0});
        $next_addtime = time + $add_interval;
    }

    # プレイリスト入れ替え処理中の場合
    if(-e $conf->{dirs}->{data} . '/newpls')
    {
        # キャッシュ待ち・追加待ち数を確認
        my $waiting = $dbh->selectrow_hashref(
            'SELECT ' .
            ' (SELECT COUNT(*) FROM files WHERE filename IS NULL) AS dl, ' .
            ' (SELECT COUNT(*) FROM programs WHERE added = 0) AS addpls',
            undef);
    
        # リクエスト再生待ち状態でなく、キャッシュ待ち・追加待ちがなければ
        if($waiting->{dl} == 0 && $waiting->{addpls} == 0)
        {
            # シャッフル
            $mpd->playlist->shuffle;
            eval { unlink($conf->{dirs}->{data} . '/newpls'); };
            logger $logdomain, "shuffle done.\n";
        }
    }

    if(!defined($mpd->song))
    {
        logger $logdomain, "Not playing, trying to restart\n";
        &mpd_set_outputs(0);
        sleep 1;
        &init_mpd;
        sleep 1;
        $mpd->play;
    }

    sleep $check_interval;

    my $song = $mpd->song;
    next if(!defined($song));

    if($song->id != $current_id)
    {
        $current_id = $song->id;

        my $r = $dbh->selectrow_hashref(
            'SELECT url, title, username, pname FROM files ' .
            'WHERE filename = ? LIMIT 1',
            undef, $song->file
        );

        my $min = int($song->time / 60);
        my $sec = $song->time - $min * 60;

        my $post = $r->{title};
        if(defined($r->{username}))
        {
            $post .= " / " . $r->{username};
            if(defined($r->{pname}))
            {
                $post .= ' (' . $r->{pname} . ')';
            }
        }
        $post = sprintf "%s (%d:%02d) %s",
            $post, $min, $sec, $r->{url};

        if(defined($request_info))
        {
            #$post = sprintf "\x{266c} %s : from @%s",
            #    $post, $request_info->{user_screen_name};
            $post = sprintf "\x{266c} %s", $post;

            my $text = $request_info->{text};
            #if($text =~ m{^\@vocaloid_fm\s+(.*?)\s*[^\s]*(?:http|(?:sm|nm)\d+)})
            if($text =~ m{^\@vocaloid_fm\s+(.*?)\s*[^\s]*(?:sm|nm)\d+})
            {
                my $comment = $1;
                if($comment ne '')
                {
                    my $rem_len = 140;
                    $rem_len -= length($post);
                    $rem_len -= length($request_info->{user_screen_name});
                    $rem_len -= 12;
                    if(length($comment) > $rem_len)
                    {
                        $comment = substr($comment, 0, $rem_len-1) . '…';
                    }

                    $post = sprintf "%s : from @%s “%s”",
                        $post,
                        $request_info->{user_screen_name},
                        $comment;
                }
            }

            # 1曲再生中につき1曲リクエスト追加するように
            $request_info = undef;
        }
        else
        {
            $post = sprintf "\x{266b} %s", $post;
        }

        # "Status is a duplicate."を避けるため
        my $dt_now = DateTime->now(time_zone => $conf->{timezone});
        $post .= $dt_now->strftime(' [%H:%M]');

        logger $logdomain, "%s\n", '-' x 40;
        logger $logdomain, "%s\n", $post;
        if($conf->{twitter}->{post_enable} == 1)
        {
            eval
            {
                $twit->update($post);
            };
            if($@)
            {
                logger $logdomain, "! post error: " . $@ . "\n";
            }
        }

        logger $logdomain, "* pos=%d, id=%d, file=%s\n",
            $song->pos, $song->id, $song->file;
    }
}

exit;


sub init_mpd
{
    &mpd_set_outputs(1);
    $mpd->fade(2);
    $mpd->repeat(1);
    $mpd->random(0);
    $mpd->volume(100);
}

sub add_playlist
{
    my $arg = shift || { request_mode => 0 };

    my $sql_reqmode = '';
    if($arg->{request_mode} == 1)
    {
        $sql_reqmode = 'AND type = 1 ORDER BY id';
    }
    else
    {
        $sql_reqmode = 'AND type = 0 ORDER BY id';
    }

    # ファイルが既に存在し、プレイリストに追加済みでないものを選択
    # TODO 初回は added = 1 のものも追加する？
    my $sth = $dbh->prepare(
        'SELECT programs.id as id, file_id, type, request_id, added, ' .
        '       url, title, filename, state, last_checked ' .
        'FROM programs ' .
        'LEFT JOIN files ON programs.file_id = files.id ' .
        'WHERE filename IS NOT NULL AND added = 0 ' .
        $sql_reqmode
    );
    $sth->execute;

    my @progs = ();
    while(my $row = $sth->fetchrow_hashref)
    {
        push(@progs, $row);
    }
    $sth->finish; undef $sth;

    if($#progs < 0)
    {
        return undef;
    }

    # ステータスチェック
    my $dl = VocaloidFM::Download->new;
    logger $logdomain, "* checking video statuses ...\n";
    foreach my $p (@progs)
    {
        my $last_checked = $p->{last_checked} || 0;
        if(time > $last_checked + $conf->{playlist}->{statuscheck_interval})
        {
            my $video_id = undef;
            if($p->{url} =~ m{watch/((?:sm|nm)\d+)$})
            {
                $video_id = $1;
            }
            else
            {
                logger $logdomain, "! can't get video id: %s\n", $p->{url};
                $p->{state} = -99;
                next;
            }

            my $s = $dl->check_status($video_id);
            if($s->{code} < 0)
            {
                logger $logdomain, "! %s: status error: %s\n",
                    $video_id, $s->{text};
            }
            else
            {
                logger $logdomain, "* %s: status OK\n", $video_id;
            }
            sleep 1;

            # 投稿者名も再取得
            my $username = $dl->get_username($video_id);
    
            # タグを調べて P 名を特定
            my $pname = $dl->get_pname($username, $s->{tags});

            # 再生数チェック 10万超なら殿堂入りフラグをオン
            my $vcount = $s->{thumbinfo}->{thumb}->{view_counter};

            $dbh->begin_work;
            $dbh->do(
                'UPDATE files SET ' .
                'title = ?, ' .
                'username = ?, ' .
                'pname = ?, ' .
                'state = ?, ' .
                "last_checked = strftime('%s', 'now'), " .
                'hof = ' . ($vcount > 100000 ? '1' : '0') . ' ' .
                'WHERE id = ?',
                undef,
                $s->{thumbinfo}->{thumb}->{title},
                $username, $pname, $s->{code}, $p->{file_id},
            );
            $dbh->commit;

            $p->{state} = $s->{code};

            next if($s->{code} < 0);

            my $title = sprintf "%s (from http://www.nicovideo.jp/watch/%s)",
                $s->{thumbinfo}->{thumb}->{title}, $video_id;

            my $artist = $username;
            if(defined($pname))
            {
                $artist .= ' (' . $pname . ')';
            }

            # タグの書き換え
            VocaloidFM::Tagger::set_comments(
                $conf->{dirs}->{songs} . '/' . $p->{filename},
                { title => $title, artist => $artist }
            )
        }
    }

    logger $logdomain, "* updating MPD database ...\n";
    my $update_time = 0;
    $mpd->updatedb;
    while(defined($mpd->status->updating_db))
    {
        sleep 1;
        last if($update_time++ >= 30);
    }

    my $reqinfo = undef;

    logger $logdomain, "* add to MPD playlist ...\n";
    foreach my $p (@progs)
    {
        #print Dump($p);
        logger $logdomain, "* [%d] %s %s\n",
            $p->{id}, $p->{filename}, $p->{title};

        if($p->{state} < 0)
        {
            logger $logdomain, "* %s is rejected by status check, skip this.\n",
                $p->{filename};

            $dbh->begin_work;
            $dbh->do(
                'UPDATE programs SET added = -1 WHERE id = ?',
                undef, $p->{id},
            );
            $dbh->commit;

            next;
        }
        elsif($p->{type} == 1)
        {
            # request mode
            my $current_pos = 0;
            if(defined(my $song = $mpd->song))
            {
                $current_pos = $song->pos;

                # 追加しようとしている曲が現在再生中ならスルー
                if($p->{filename} eq $mpd->song->file)
                {
                    logger $logdomain, "* %s is now playing, skip this.\n",
                        $p->{filename};

                    # FIXME
                    $dbh->begin_work;
                    $dbh->do(
                        'UPDATE programs SET added = -1 WHERE id = ?',
                        undef, $p->{id},
                    );
                    $dbh->commit;
                    next;
                }
            }

            # 追加しようとしている曲が既にプレイリストにあるなら削除
            # TODO 非リクエストモードでも同様にする？
            my @items = $mpd->playlist->as_items;
            foreach my $song (@items)
            {
                if($song->file eq $p->{filename})
                {
                    logger $logdomain, "* %s exists in playlist (pos=%d), so delete it.\n",
                        $p->{filename}, $song->pos;
                    $mpd->playlist->delete($song->pos);
                }
            }

            # 再取得
            $current_pos = $mpd->song->pos;
            @items = $mpd->playlist->as_items;
            my $pls_length = $#items + 1;

            # リクエスト者の情報を得ておく
            if(defined($p->{request_id}))
            {
                $reqinfo = $dbh->selectrow_hashref(
                    'SELECT * FROM replies WHERE id = ? LIMIT 1',
                    undef, $p->{request_id}
                );
            }

            #printf " MPD playing: [%d/%d]\n", $current_pos+1, $pls_length;

            # 追加して現在再生中の曲の次へ移動
            eval {
                $mpd->playlist->add($p->{filename});
                if($pls_length > 0)
                {
                    logger $logdomain, "* move from %d to %d\n",
                        $pls_length, $current_pos+1;
                    $mpd->playlist->move($pls_length, $current_pos+1);
                }
            };
            if($@)
            {
                logger $logdomain, "ERROR while adding: %s\n", $@;
                next;
            }

            # TODO リクエストで追加した曲の削除は？

            $dbh->begin_work;
            $dbh->do(
                'UPDATE programs SET added = 1 WHERE id = ?',
                undef, $p->{id},
            );
            $dbh->commit;

            # リクエストモードでは一曲追加したら終わり
            last;
        }
        else
        {
            # normal mode

            # プレイリストの末尾に追加
            eval {
                $mpd->playlist->add($p->{filename});
            };
            if($@)
            {
                logger $logdomain, "ERROR while adding: %s\n", $@;
                next;
            }
            $dbh->begin_work;
            $dbh->do(
                'UPDATE programs SET added = 1 WHERE id = ?',
                undef, $p->{id},
            );
            $dbh->commit;
        }
    }

    return $reqinfo;
}

sub stop
{
    $mainloop = 0;
}

sub mpd_set_outputs
{
    my $enable = shift || return undef;

    foreach(@{$conf->{mpd}->{outputs}})
    {
        if($enable == 1)
        {
            $mpd->output_enable($_);
        }
        else
        {
            $mpd->output_disable($_);
        }
    }
}

sub log
{
    my $str = shift || return;
    my $dt_now = DateTime->now(time_zone => $conf->{timezone});

    printf "[%s] %s", $dt_now->strftime('%Y/%m/%d %H:%M:%S'), $str;
    open FH, '>>:encoding(utf8)', $conf->{logfile} or return;
    printf FH "[%s] %s", $dt_now->strftime('%Y/%m/%d %H:%M:%S'), $str;
    close FH;
}

