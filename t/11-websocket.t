#!/usr/bin/env perl

use v5.38;
use Test::More;
use Future::AsyncAwait;
use JSON::PP qw(decode_json);
use PAGI::FastAPI;
use PAGI::FastAPI::Depends qw(Depends);
use PAGI::Test::ConnectionState;

my $app = PAGI::FastAPI->new(title => 'WebSocket Test App');

# Simple echo WebSocket endpoint
$app->websocket('/ws/echo',
    handler => async sub ($ws, $deps) {
        await $ws->accept;

        while (my $msg = await $ws->receive_text) {
            await $ws->send_text("Echo: $msg");
        }
    }
);

# WebSocket endpoint with path params, JSON messaging, and explicit close
$app->websocket('/ws/chat/{room}',
    handler => async sub ($ws, $deps) {
        my $room = $ws->path_params->{room};
        await $ws->accept;

        my $data = await $ws->receive_json;
        if ($data->{action} eq 'ping') {
            await $ws->send_json({ room => $room, status => 'pong' });
        }

        await $ws->close(1000, "Done");
    }
);

my $pagi_app = $app->to_app;

# A hand-built websocket scope needs the pagi.connection object a PAGI Www
# 0.6 server provides; a peer disconnect is recorded on it before the
# application sees the event, as a server does. An application's own Close
# is answered at once, as a cooperative peer does, so the closing handshake
# completes and the call -- which ends with the connection -- can finish.
sub ws_scope ($path) {
    my $conn = PAGI::Test::ConnectionState->new(websocket => 1);
    my $scope = {
        type              => 'websocket',
        path              => $path,
        query_string      => '',
        headers           => [],
        'pagi.connection' => $conn,
    };
    my $peer_closed = sub ($event) {
        if ($event->{type} eq 'websocket.disconnect') {
            $conn->_set_peer_close($event->{code} // 1005, $event->{reason} // '');
            $conn->_mark_complete;
        }
        return $event;
    };
    my $answer_close = sub ($event) {
        if ($event->{type} eq 'websocket.close' && $conn->is_connected) {
            $conn->_set_peer_close($event->{code} // 1000, $event->{reason} // '');
            $conn->_mark_complete;
        }
        return;
    };
    return ($scope, $peer_closed, $answer_close);
}

subtest 'Valid WebSocket Handshake and Echo Flow' => sub {
    my ($scope, $peer_closed) = ws_scope('/ws/echo');

    # Queue of incoming client events
    my @incoming_events = (
        { type => 'websocket.receive', text => 'Hello Perl' },
        { type => 'websocket.disconnect', code => 1000 },
    );

    my @sent_events;

    my $receive = async sub {
        return $peer_closed->(shift @incoming_events);
    };

    my $send = async sub ($event) {
        push @sent_events, $event;
    };

    # Resolve async execution with ->get
    $pagi_app->($scope, $receive, $send)->get;

    is scalar(@sent_events), 2, 'Received two outgoing events';
    is $sent_events[0]->{type}, 'websocket.accept', 'First event was websocket.accept';
    is $sent_events[1]->{type}, 'websocket.send', 'Second event was websocket.send';
    is $sent_events[1]->{text}, 'Echo: Hello Perl', 'Echo text payload is correct';
};

subtest 'WebSocket Route with Path Params, JSON Payload, and Handshake Close' => sub {
    my ($scope, $peer_closed, $answer_close) = ws_scope('/ws/chat/lobby');

    my @incoming_events = (
        { type => 'websocket.receive', text => '{"action":"ping"}' },
    );

    my @sent_events;

    my $receive = async sub {
        return $peer_closed->(shift @incoming_events // { type => 'websocket.disconnect', code => 1000 });
    };

    my $send = async sub ($event) {
        push @sent_events, $event;
        $answer_close->($event);
    };

    $pagi_app->($scope, $receive, $send)->get;

    is scalar(@sent_events), 3, 'Received accept, json message, and close events';
    is $sent_events[0]->{type}, 'websocket.accept', 'Handshake accepted';

    is $sent_events[1]->{type}, 'websocket.send', 'JSON message event sent';
    my $data = decode_json($sent_events[1]->{text});
    is $data->{room}, 'lobby', 'Path parameter accessible in WebSocket handler';
    is $data->{status}, 'pong', 'JSON response payload is correct';

    is $sent_events[2]->{type}, 'websocket.close', 'Connection closed cleanly';
    is $sent_events[2]->{code}, 1000, 'Close code 1000 sent';
};

subtest 'Non-existent route refuses the handshake with HTTP 404' => sub {
    my ($scope, $peer_closed) = ws_scope('/ws/nonexistent');

    my @sent_events;

    my $receive = async sub { return { type => 'websocket.connect' } };
    my $send    = async sub ($event) {
        push @sent_events, $event;
    };

    $pagi_app->($scope, $receive, $send)->get;

    # PAGI Www 0.6: before accept the connection is still an HTTP exchange,
    # so it is refused with an HTTP response; websocket.close is not allowed.
    is $sent_events[0]->{type}, 'http.response.start', 'Handshake refused with an HTTP response';
    is $sent_events[0]->{status}, 404, 'Status 404 Not Found';
    ok !(grep { $_->{type} eq 'websocket.close' } @sent_events), 'No websocket.close before accept';
};

# Each way _handle_websocket ends a socket it did not hand to a handler.
sub run_ws ($app, $path) {
    my ($scope, undef, $answer_close) = ws_scope($path);
    my @sent;
    my $receive = async sub { return { type => 'websocket.connect' } };
    my $send    = async sub ($event) { push @sent, $event; $answer_close->($event); return };
    my $died;
    eval { $app->to_app->($scope, $receive, $send)->get; 1 } or $died = $@;
    return (\@sent, $died, $scope);
}

subtest 'A failing dependency refuses the handshake with HTTP 403' => sub {
    my $app = PAGI::FastAPI->new;
    $app->websocket('/ws/private',
        dependencies => [ Depends(async sub ($ws) { die "no token\n" }, key => 'user') ],
        handler => async sub ($ws, $deps) { await $ws->accept });
    my ($sent, $died) = run_ws($app, '/ws/private');
    is $died, undef, 'the application does not die';
    is $sent->[0]{status}, 403, 'Status 403';
    like $sent->[1]{body}, qr/\AUnauthorized: no token/, 'the body names the failure';
    ok !(grep { $_->{type} eq 'websocket.close' } @$sent), 'No websocket.close before accept';
};

subtest 'A handler error before accept is an HTTP 500' => sub {
    my $app = PAGI::FastAPI->new;
    $app->websocket('/ws/broken', handler => async sub ($ws, $deps) { die "bug\n" });
    my ($sent, $died) = run_ws($app, '/ws/broken');
    is $died, undef, 'the application does not die';
    is $sent->[0]{status}, 500, 'Status 500';
};

subtest 'A handler error after accept closes with 1011' => sub {
    my $app = PAGI::FastAPI->new;
    $app->websocket('/ws/broken-later', handler => async sub ($ws, $deps) {
        await $ws->accept;
        die "bug\n";
    });
    my ($sent, $died) = run_ws($app, '/ws/broken-later');
    is $died, undef, 'the application does not die';
    is_deeply [map { $_->{type} } @$sent], ['websocket.accept', 'websocket.close'], 'accept, then Close';
    is_deeply [@{ $sent->[1] }{qw(code reason)}], [1011, 'Internal Server Error'], 'code 1011';
};

subtest 'A client that hangs up during a dependency: nothing is sent, nothing dies' => sub {
    my $app = PAGI::FastAPI->new;
    $app->websocket('/ws/slow',
        dependencies => [ Depends(async sub ($ws) {
            $ws->scope->{'pagi.connection'}->_mark_disconnected('client_closed');
            die "no token\n";
        }, key => 'user') ],
        handler => async sub ($ws, $deps) { await $ws->accept });
    my ($sent, $died) = run_ws($app, '/ws/slow');
    is $died, undef, 'the application does not die';
    is_deeply $sent, [], 'nothing is sent';
};

done_testing;
