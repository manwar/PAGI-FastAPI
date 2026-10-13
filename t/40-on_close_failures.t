#!/usr/bin/env perl

use v5.38;
use Test::More;
use Future;
use Future::AsyncAwait;

use PAGI::FastAPI;
use PAGI::FastAPI::Response::SSE;
use PAGI::Test::Client;
use PAGI::Test::ConnectionState;

# A WebSocket or SSE handler's on_close cleanup is part of its call, as it is
# for PAGI::Tools routes: the call waits for it, and an on_close that dies
# fails the call (the server logs it) instead of vanishing.

subtest 'a WebSocket route whose on_close dies fails its call' => sub {
    my $app = PAGI::FastAPI->new();
    $app->websocket('/ws', handler => async sub ($ws, $deps) {
        await $ws->accept;
        $ws->on_close(sub { die "ws cleanup broke\n" });
        await $ws->each_text(async sub ($text) { });
    });
    my $client = PAGI::Test::Client->new(app => $app->to_pagi);
    my $error = eval { $client->websocket('/ws', sub ($ws) { $ws->send_text('hi') }); 1 } ? '' : $@;
    like($error, qr/ws cleanup broke/, 'the on_close failure reaches the caller');
};

subtest 'an SSE response whose on_close dies fails its dispatch' => sub {
    my $conn  = PAGI::Test::ConnectionState->new;
    my $scope = { type => 'sse', path => '/stream', 'pagi.connection' => $conn };
    my $send  = sub ($event) {
        $conn->_mark_complete if $event->{type} eq 'sse.close';
        return Future->done;
    };
    my $response = PAGI::FastAPI::Response::SSE->new(
        generator => async sub ($sse) {
            $sse->on_close(sub { die "sse cleanup broke\n" });
            await $sse->send('hello');
            await $sse->close;
        },
    );
    my $dispatch = $response->dispatch($scope, sub { Future->new }, $send);
    ok($dispatch->is_ready, 'the dispatch has finished');
    ok($dispatch->is_failed, 'and failed');
    like(scalar(($dispatch->failure)[0] // ''), qr/sse cleanup broke/, 'with the on_close failure');
};

done_testing;
