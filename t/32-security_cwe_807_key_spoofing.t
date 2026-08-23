#!/usr/bin/env perl

use v5.38;
use Test::More;

use Future;
use PAGI::FastAPI::Middleware::RateLimit;

package MockContext {
    sub new ($class, %args)   { bless \%args, $class       }
    sub scope ($self)         { $self->{scope}             }
    sub header ($self, $name) { $self->{headers}{lc $name} }
    sub add_header {}
    sub set_header {}
    sub status     {}
}

my $peer_ip = '192.168.1.100';

my $limiter = PAGI::FastAPI::Middleware::RateLimit->new(
    requests => 2,
    window   => 60,
);

my $c1 = MockContext->new(
    scope   => { client => [$peer_ip] },
    headers => { 'x-forwarded-for' => '1.1.1.1', 'x-api-key' => 'key1' }
);
my $c2 = MockContext->new(
    scope   => { client => [$peer_ip] },
    headers => { 'x-forwarded-for' => '2.2.2.2', 'x-api-key' => 'key2' }
);

# First two requests consume the quota
$limiter->handle($c1, sub { Future->done('ok') })->get;
$limiter->handle($c2, sub { Future->done('ok') })->get;

# 3rd request from same socket IP should be blocked despite spoofed headers
my $res = $limiter->handle($c2, sub { Future->done('ok') })->get;

is_deeply(
    $res,
    {
        detail      => 'Too Many Requests',
        message     => 'API rate limit exceeded. Please try again later.',
        retry_after => 60,
    },
    'Blocked third request from same IP despite changing headers'
);

done_testing;
