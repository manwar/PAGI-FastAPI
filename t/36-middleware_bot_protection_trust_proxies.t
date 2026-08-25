#!/usr/bin/env perl

use v5.38;
use experimental 'class';
use Test::More;

use Future;
use Digest::SHA qw(sha256_hex);
use PAGI::FastAPI::Middleware::BotProtection;
use PAGI::FastAPI::BotProtection::ProofOfWork;

class MockContext {
    field $headers           :param = {};
    field $scope             :param = {};
    field $_status           = undef;
    field $_response_headers = {};
    field $_rendered         = undef;

    method header ($name) { return $headers->{lc($name)} }
    method scope ()       { return $scope }

    method status ($val = undef) {
        $_status = $val if defined $val;
        return $_status;
    }

    method set_header ($k, $v) { $_response_headers->{$k} = $v }
    method render (%args)      { $_rendered = \%args; return $self }

    method rendered ()         { return $_rendered }
    method response_headers () { return $_response_headers }
}

sub solve_challenge ($challenge, $difficulty = 1) {
    my $target = '0' x $difficulty;
    for (my $nonce = 0; $nonce < 1_000_000; $nonce++) {
        my $digest = sha256_hex("${challenge}:${nonce}");
        return $nonce if substr($digest, 0, $difficulty) eq $target;
    }
    die "Could not solve challenge within search space";
}

subtest 'BotProtection client IP and trust_proxies behaviour' => sub {
    my $secret    = 'test-secret-key';
    my $make_next = sub ($tracker_ref) {
        return sub ($ctx) {
            $$tracker_ref = 1;
            return Future->done('OK');
        };
    };

    # Test 1: trust_proxies => 0 ignores X-Forwarded-For and verifies via peer IP
    {
        my $mw = PAGI::FastAPI::Middleware::BotProtection->new(
            secret        => $secret,
            trust_proxies => 0,
            difficulty    => 1,
        );

        my $peer_ip    = '192.168.1.10';
        my $spoofed_ip = '203.0.113.99';

        # Step 1: Issue challenge via initial unauthenticated request to middleware
        my $c_init = MockContext->new(
            scope   => { client => [$peer_ip, 12345] },
            headers => { 'x-forwarded-for' => $spoofed_ip },
        );
        $mw->handle($c_init, sub { Future->done('OK') })->get;

        my $ch_header = $c_init->response_headers->{'x-bot-challenge'};
        my $nonce     = solve_challenge($ch_header, 1);

        # Step 2: Request with valid solved nonce
        my $c = MockContext->new(
            scope   => { client => [$peer_ip, 12345] },
            headers => {
                'x-forwarded-for' => $spoofed_ip,
                'x-bot-challenge' => $ch_header,
                'x-bot-nonce'     => $nonce,
            },
        );

        my $next_called = 0;
        my $next        = $make_next->(\$next_called);

        $mw->handle($c, $next)->get;
        is($next_called, 1, 'passes to next handler when challenge matches peer IP');
    }

    # Test 2: Spoofed header challenge replay fails when trust_proxies => 0
    {
        my $mw = PAGI::FastAPI::Middleware::BotProtection->new(
            secret        => $secret,
            trust_proxies => 0,
            difficulty    => 1,
        );

        my $peer_ip    = '192.168.1.10';
        my $spoofed_ip = '203.0.113.99';

        # Generate challenge issued specifically to spoofed IP
        my $pow = PAGI::FastAPI::BotProtection::ProofOfWork->new(
            secret     => $secret,
            difficulty => 1,
        );
        my $ch    = $pow->create_challenge($spoofed_ip);
        my $nonce = solve_challenge($ch->{challenge}, 1);

        my $c = MockContext->new(
            scope   => { client => [$peer_ip, 12345] },
            headers => {
                'x-forwarded-for' => $spoofed_ip,
                'x-bot-challenge' => $ch->{challenge},
                'x-bot-nonce'     => $nonce,
            },
        );

        my $next_called = 0;
        my $next        = $make_next->(\$next_called);

        $mw->handle($c, $next)->get;

        is($next_called, 0, 'blocks request when challenge is bound to spoofed header');
        is($c->status, 401, 'returns 401 Unauthorized status');
    }

    # Test 3: Explicit trust_proxies => 1 trusts X-Forwarded-For
    {
        my $mw = PAGI::FastAPI::Middleware::BotProtection->new(
            secret        => $secret,
            trust_proxies => 1,
            difficulty    => 1,
        );

        my $peer_ip  = '192.168.1.10';
        my $proxy_ip = '203.0.113.50';

        # Step 1: Issue challenge via middleware to capture exact state/headers
        my $c_init = MockContext->new(
            scope   => { client => [$peer_ip, 12345] },
            headers => { 'x-forwarded-for' => $proxy_ip },
        );
        $mw->handle($c_init, sub { Future->done('OK') })->get;

        my $ch_header = $c_init->response_headers->{'x-bot-challenge'};
        my $nonce     = solve_challenge($ch_header, 1);

        # Step 2: Pass solved challenge with trusted proxy IP header
        my $c = MockContext->new(
            scope   => { client => [$peer_ip, 12345] },
            headers => {
                'x-forwarded-for' => $proxy_ip,
                'x-bot-challenge' => $ch_header,
                'x-bot-nonce'     => $nonce,
            },
        );

        my $next_called = 0;
        my $next        = $make_next->(\$next_called);

        $mw->handle($c, $next)->get;
        is($next_called, 1, 'passes to next handler when proxy IP is trusted');
    }
};

done_testing;
