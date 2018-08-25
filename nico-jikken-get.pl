#!/bin/perl
# 使い方
# 引数としてlv{NUMBER}を含む文字列を渡す
use strict;
use warnings;
use v5.20;
use LWP::UserAgent;
use JSON;
use URI;
use DBI;

my $livdId;
for(@ARGV) {
	if(m{(lv\d+)}) {
		$livdId = $1;
	}
}
unless($livdId) {
	die "live id required";
}

my $session = do "./session.txt" // die "session.txt not found";

my $dbfile = "${livdId}.sqilte3";
my $tsfile = "${livdId}.ts";

my $ua = LWP::UserAgent->new(keep_alive => 1);
$ua->agent("Mozilla/5.0 (nico-jikken-get.pl @ himananiito)");

my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","");

$SIG{INT} = sub {
	say "interrupted";
	$dbh->commit;
	exit;
};
$dbh->begin_work;

$dbh->do(qq{
	create table if not exists media (
		seqno integer primary key not null unique,
		pos real,
		data blob
	);
});

sub existsSeq($) {
	my($seqno) = @_;
	my $sth = $dbh->prepare("select 1 from media where seqno = ? limit 1");
	$sth->execute($seqno);
	my @a  = $sth->fetchrow_array;
	scalar @a;
}

sub lastPos() {
	my $sth = $dbh->prepare("select pos from media order by seqno desc limit 1");
	$sth->execute();
	my @a  = $sth->fetchrow_array;
	$a[0] // 0;
}
sub getPos($) {
	my($seqno) = @_;
	my $sth = $dbh->prepare("select pos from media where seqno = ? limit 1");
	$sth->execute($seqno);
	my @a  = $sth->fetchrow_array;
	$a[0] // 0;
}

sub insert($$$) {
	my($seqno, $pos, $data) = @_;
	my $sth = $dbh->prepare("insert or ignore into media(seqno, pos, data) values(?, ?, ?)");
	$sth->execute($seqno, $pos, $data);
}

sub getTrackerId {
	my $s = $ua->request(HTTP::Request->new(POST => 'https://public.api.nicovideo.jp/v1/action-track-ids.json', [
		#"User-Agent" => "niconico/6.65.2 CFNetwork/811.5.4 Darwin/16.7.0",
	]))->decoded_content;
	from_json($s)->{data} // die "fail: action-track-ids";
}

sub getMasterUrl {
	my $res = $ua->request(HTTP::Request->new(
		POST => "https://api.cas.nicovideo.jp/v1/services/live/programs/${livdId}/watching-archive", [
			"Content-Type" => "application/json",
			"X-Frontend-Id" => "91",
			"X-Connection-Environment" => "ethernet",
			"Cookie" => $session,
		], to_json({
			actionTrackId => getTrackerId(),
			streamCapacity => "superhigh",
			streamProtocol => "https",
			streamQuality => "auto",
		})
	));
	say $res->as_string;

	my $data = from_json($res->decoded_content);
	$data->{data}->{streamServer}->{url} // "fail: watching-archive";
}

# arg1: base url, arg2: time as second
# ret1: url
sub getPlaylistMasterWithTime($$) {
	my($base, $start) = @_;
	my $url = "${base}&start=${start}";

	my $re = $ua->get($url);
	my $s = $re->as_string;

	my $max = 0;
	my $maxPath;
	while($s =~ m{
		\#EXT-X-STREAM-INF:BANDWIDTH=(\d+)[^\n]*\n
		([^\r\n]+)
	}gsx) {
		say "$1 -> $2";
		if($1 > $max) {
			$max = $1;
			$maxPath = $2;
		}
	}
	URI->new_abs($maxPath, $base);
}

# arg1: url
# ret1: http code
my $SEQ = -1;
sub downloadChunk($$$) {
	my($seq, $time, $url) = @_;
	return if existsSeq($seq);

	warn "$seq -> $url";

	my $re = $ua->get($url);
	if($re->code == 200) {
		insert($seq, $time, $re->content);
		if($seq != $SEQ + 1) {
			if($SEQ >= 0) {
				die "sequence wrong: $seq != $SEQ";
			}
		}
		$SEQ = $seq;
	}
	return $re->code;
}

# arg1: playlist url
sub getPlaylist($$) {
	my($url, $time) = @_;
	my $re = $ua->get($url);
	if($re->code == 403) {
		return($re->code, 0, 0);
	}
	my $s = $re->decoded_content;
	say ">>>$s<<<";

	my $seq;
	if($s =~ m{#EXT-X-MEDIA-SEQUENCE:(\d+)[\r\n\s]}) {
		$seq = $1;
	} else {
		say $re->decoded_content;
		die "notfound: #EXT-X-MEDIA-SEQUENCE";
	}

	my $sum = 0;
	while($s =~ m{#EXTINF:([\+\-]?\d+(?:\.\d+)?(?:[eE][\+\-]?\d+)?)[^\n]*\n(\S+)}g) {
		#say "$1 $2";
		my $code = downloadChunk($seq, $time, URI->new_abs($2, $url)) // 0;
		if($code == 403) {
			return($re->code, 0, 0);
		}

		$sum += eval $1;
		$seq++;
	}

	my $end = 0;
	if($s =~ m{#EXT-X-ENDLIST}) {
		say "playlist end";
		$end = 1;
	}

	return ($re->code, $sum, $end);
}

# arg1: 取得を開始する時間
# arg2:ループ回数(お試し用)
sub getWithTime($$) {
	my($time, $loopCnt) = @_;

	$dbh->commit;
	$dbh->begin_work;

	my $base = getMasterUrl();

	my $cnt403;
	while(1) {
		my($code, $sum, $end) = getPlaylist(getPlaylistMasterWithTime($base, $time), $time);
		if($end) {
			last;
		}
		if($code == 403) {
			$cnt403++;
			if($cnt403 > 2) {
				die "fail: limit 403";
			}
			$base = getMasterUrl();
			next;

		} else {
			$cnt403 = 0;
		}

		if($loopCnt > 0) {
			if(--$loopCnt == 0) {
				last;
			}
		}

		$time += $sum;
		#warn $time;
		for(1..5) {
			sleep 1;
		}
	}
	$dbh->commit;
}
getWithTime(lastPos(), -1);

# MPEG2TSに書き出す
sub simpleJoin() {
	my $sth = $dbh->prepare("select seqno, data from media order by seqno asc");
	$sth->execute();
	my $prev = -1;
	open my $f, ">:raw", $tsfile or die;
	while(my($seqno, $data) = $sth->fetchrow_array) {
		say "writing $tsfile: $seqno";
		if($prev + 1 != $seqno) {
			# そもそもここに来ないようにしたい
			getWithTime(getPos($prev), 2); # お試し
			die "fail: seqno skipped";
		}
		$prev = $seqno;
		print $f $data;
	}
	close $f;
}
simpleJoin();
