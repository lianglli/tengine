#!/usr/bin/perl

# Copyright (C) 2010-2015 Alibaba Group Holding Limited

# Tests for active health checks of stream upstreams.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream http upstream_check/)->plan(10)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;
worker_processes 1;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen      127.0.0.1:%%PORT_8080%%;
        server_name localhost;

        location /status {
            check_status;
            access_log off;
        }
    }
}

stream {
    %%TEST_GLOBALS_STREAM%%

    # 8081 is served by a daemon, 8082 is a closed port throughout the test
    upstream u_rr {
        server 127.0.0.1:%%PORT_8081%%;
        server 127.0.0.1:%%PORT_8082%%;

        check interval=200 rise=1 fall=1 timeout=150 type=tcp;
    }

    upstream u_hash {
        hash $remote_addr;
        server 127.0.0.1:%%PORT_8081%%;
        server 127.0.0.1:%%PORT_8082%%;

        check interval=200 rise=1 fall=1 timeout=150 type=tcp;
    }

    upstream u_least_conn {
        least_conn;
        server 127.0.0.1:%%PORT_8081%%;
        server 127.0.0.1:%%PORT_8082%%;

        check interval=200 rise=1 fall=1 timeout=150 type=tcp;
    }

    upstream u_random {
        random;
        server 127.0.0.1:%%PORT_8081%%;
        server 127.0.0.1:%%PORT_8082%%;

        check interval=200 rise=1 fall=1 timeout=150 type=tcp;
    }

    upstream u_least_time {
        least_time first_byte;
        server 127.0.0.1:%%PORT_8081%%;
        server 127.0.0.1:%%PORT_8082%%;

        check interval=200 rise=1 fall=1 timeout=150 type=tcp;
    }

    # the forwarded port is closed, the probed one is not: with "port=" the
    # peer must still come up
    upstream u_port {
        server 127.0.0.1:%%PORT_8085%%;

        check interval=200 rise=1 fall=1 timeout=150 type=tcp
              port=%%PORT_8081%%;
    }

    # 8086 only starts listening a few seconds in, so it is first seen down
    # and must come back up on its own
    upstream u_late {
        server 127.0.0.1:%%PORT_8086%%;

        check interval=200 rise=1 fall=1 timeout=150 type=tcp;
    }

    server {
        listen      127.0.0.1:%%PORT_8090%%;
        proxy_pass  u_rr;
    }

    server {
        listen      127.0.0.1:%%PORT_8091%%;
        proxy_pass  u_hash;
    }

    server {
        listen      127.0.0.1:%%PORT_8092%%;
        proxy_pass  u_least_conn;
    }

    server {
        listen      127.0.0.1:%%PORT_8093%%;
        proxy_pass  u_random;
    }

    server {
        listen      127.0.0.1:%%PORT_8094%%;
        proxy_pass  u_least_time;
    }
}

EOF

$t->run_daemon(\&stream_daemon, port(8081));
$t->run_daemon(\&stream_daemon, port(8086), 4);
$t->run();

$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

my ($port1, $port2) = (port(8081), port(8082));

# Peers start out down (default_down defaults to true) and the first probe only
# fires after a random delay of up to max(interval, 1s), so wait for the first
# verdict before asserting anything.
select undef, undef, undef, 2.5;

is(many(port(8090), 10), "$port1: 10", 'round-robin skips the down peer');
is(many(port(8091), 10), "$port1: 10", 'hash skips the down peer');
is(many(port(8092), 10), "$port1: 10", 'least_conn skips the down peer');
is(many(port(8093), 10), "$port1: 10", 'random skips the down peer');
is(many(port(8094), 10), "$port1: 10", 'least_time skips the down peer');

my $status = get_status();

like($status, qr!^\d+,u_rr,127\.0\.0\.1:$port1,up,\d+,\d+,tcp,0,stream$!m,
	'status page reports the stream peer that is up');
like($status, qr!^\d+,u_rr,127\.0\.0\.1:$port2,down,\d+,\d+,tcp,0,stream$!m,
	'status page reports the stream peer that is down');

# "port=" is reported in the status page and redirects the probe: the peer's own
# port is closed, so it could only have come up by being probed on port 8081
like($status, qr!^\d+,u_port,127\.0\.0\.1:@{[port(8085)]},up,\d+,\d+,tcp,@{[port(8081)]},stream$!m,
	'"port=" probes a different port');

# The late peer is not listening yet at this point.
like($status, qr!^\d+,u_late,127\.0\.0\.1:@{[port(8086)]},down,!m,
	'peer that is not listening yet is down');

# It starts listening 4s in; give the check one more interval to see it rise.
$t->waitforsocket('127.0.0.1:' . port(8086));
select undef, undef, undef, 1;

like(get_status(), qr!^\d+,u_late,127\.0\.0\.1:@{[port(8086)]},up,!m,
	'peer comes back up once it listens');

###############################################################################

sub get_status {
	my $r = http_get('/status?format=csv');
	$r =~ s/.*?\x0d\x0a\x0d\x0a//s;
	return $r;
}

sub many {
	my ($port, $count) = @_;
	my (%ports);

	for (1 .. $count) {
		if (stream('127.0.0.1:' . $port)->io('.') =~ /(\d+)/) {
			$ports{$1} = 0 unless defined $ports{$1};
			$ports{$1}++;
		}
	}

	return join ', ', map { $_ . ": " . $ports{$_} } sort keys %ports;
}

###############################################################################

sub stream_daemon {
	my ($port, $delay) = @_;

	# a peer that only starts listening later is first seen as down
	select undef, undef, undef, $delay if defined $delay;

	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1',
		LocalPort => $port,
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	my $sel = IO::Select->new($server);

	local $SIG{PIPE} = 'IGNORE';

	while (my @ready = $sel->can_read) {
		foreach my $fh (@ready) {
			if ($server == $fh) {
				my $new = $fh->accept;
				$new->autoflush(1);
				$sel->add($new);

			} elsif (stream_handle_client($fh)) {
				$sel->remove($fh);
				$fh->close;
			}
		}
	}
}

sub stream_handle_client {
	my ($client) = @_;

	$client->sysread(my $buffer, 65536) or return 1;

	$client->syswrite($client->sockport());

	return 1;
}

###############################################################################
