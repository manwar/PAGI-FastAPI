package PAGI::FastAPI::Middleware::BotProtection;

use v5.38;
use experimental 'class';
use version;

our $VERSION   = qv('v1.7.3');
our $AUTHORITY = 'cpan:MANWAR';

use Future::AsyncAwait;
use PAGI::FastAPI::BotProtection::ProofOfWork;

class PAGI::FastAPI::Middleware::BotProtection {
    field $difficulty    :param = 3;
    field $ttl           :param = 300;
    field $trust_proxies :param = 0;
    field $secret        :param;
    field $pow;

    ADJUST {
        die "BotProtection: 'secret' parameter must be defined and non-empty in production\n"
            unless defined $secret && length($secret) > 0;

        $pow = PAGI::FastAPI::BotProtection::ProofOfWork->new(
            difficulty => $difficulty,
            secret     => $secret,
            ttl        => $ttl,
        );
    }

    method pow () { return $pow }

    async method handle ($c, $next) {
        my $client_ip;
        if ($trust_proxies && (my $forwarded = $c->header('x-forwarded-for'))) {
            ($client_ip) = split /\s*,\s*/, $forwarded;
        }
        $client_ip //= $c->scope->{client}[0] // '127.0.0.1';

        # Standard header keys expected from client requests
        my $challenge = $c->header('x-bot-challenge');
        my $nonce     = $c->header('x-bot-nonce');

        # Allow request to proceed if valid Proof-of-Work token is provided
        if ($pow->verify($challenge, $nonce, $client_ip)) {
            return await $next->($c);
        }

        # Issue new challenge and return HTTP 401 Unauthorized
        my $ch = $pow->create_challenge($client_ip);

        $c->status(401);
        $c->set_header('x-bot-challenge'  => $ch->{challenge});
        $c->set_header('x-bot-difficulty' => $ch->{difficulty});

        return {
            detail  => 'Bot Protection Triggered',
            message => 'Proof-of-Work challenge required to access this endpoint.',
        };
    }
}

=encoding utf-8

=head1 NAME

PAGI::FastAPI::Middleware::BotProtection - Asynchronous Proof-of-Work Bot Protection Middleware for PAGI::FastAPI

=head1 VERSION

Version v1.7.3

=head1 SYNOPSIS

    use PAGI::FastAPI;

    my $app = PAGI::FastAPI->new();

    # Register bot protection middleware
    $app->add_bot_protection(
        difficulty => 3,
        secret     => $ENV{BOT_PROTECTION_SECRET} // die("BOT_PROTECTION_SECRET is required"),
        ttl        => 300,
    );

=head1 DESCRIPTION

C<PAGI::FastAPI::Middleware::BotProtection> integrates cryptographic
Proof-of-Work bot mitigation into L<PAGI::FastAPI> application request
pipelines.

When active, incoming requests without a valid C<X-Bot-Challenge> and
C<X-Bot-Nonce> header are rejected with an HTTP C<401 Unauthorized>
response accompanied by challenge parameters in the response headers. Real
client environments (such as web browsers executing background JavaScript)
solve the puzzle and retry the request, bypassing automated bots and naive
scrapers.

=head1 CONSTRUCTOR

=head2 new(%options)

Creates a new instance of L<PAGI::FastAPI::Middleware::BotProtection>.

Accepted options:

=over 4

=item * C<secret> (required)

A non-empty string used as the C<HMAC> key to sign and verify generated
challenges.

B<Security Note:> Keep this value secure and avoid using hardcoded default
strings in production environments.

=item * C<difficulty> (optional)

An integer specifying the required leading zero bits (or hexadecimal zeros)
for the Proof-of-Work solution. Defaults to C<3>.

Higher values exponentially increase the CPU time required for the client to
generate a valid nonce, while lower values reduce client computation
overhead.

=item * C<ttl> (optional)

The time-to-live duration for issued challenges, in seconds. Defaults to
C<300> (5 minutes).

Challenges presented after this time window has elapsed will be rejected as
expired, requiring the client to request a fresh challenge.

=item * C<trust_proxies> (optional)

Boolean flag indicating whether to trust incoming proxy headers for client
IP resolution. Defaults to C<0> (false).

When set to C<0>, the middleware extracts the client IP strictly from the
direct TCP connection socket, ignoring client-supplied headers. When set to
C<1>, the middleware parses the first IP from the C<X-Forwarded-For> header
if present.

B<Security Note:> Only set C<trust_proxies> to C<1> when running behind a
trusted reverse proxy (such as NGINX, HAProxy, or AWS ALB) that strips or
overwrites incoming client header values.

=back

=head1 METHODS

=head2 pow

    my $pow = $mw->pow;

Returns the underlying L<PAGI::FastAPI::BotProtection::ProofOfWork> instance
managed by this middleware.

This accessor exposes the Proof-of-Work engine directly to callers, allowing
custom challenge creation (via C<create_challenge>), manual verification
(via C<verify>), or direct inspection during testing and advanced
application integrations.

=head1 HEADERS

The middleware inspects and sets the following HTTP response/request headers:

=over 4

=item * C<x-bot-challenge> (Request/Response)

The HMAC-signed challenge token string issued by the server.

=item * C<x-bot-difficulty> (Response)

The integer difficulty level assigned to the active challenge.

=item * C<x-bot-nonce> (Request)

The integer solution nonce computed by the client.

=back

=head1 SEE ALSO

L<PAGI::FastAPI::BotProtection::ProofOfWork>, L<PAGI::FastAPI>

=head1 AUTHOR

Mohammad Sajid Anwar, C<< <mohammad.anwar at yahoo.com> >>

=head1 BUGS

Please report any bugs or feature requests through the web interface at L<https://github.com/manwar/PAGI-FastAPI/issues>.
I will be notified and then you'll automatically be notified of progress on your
bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc PAGI::FastAPI::Middleware::BotProtection

You can also look for information at:

=over 4

=item * BUG Report

L<https://github.com/manwar/PAGI-FastAPI/issues>

=item * Search MetaCPAN

L<https://metacpan.org/dist/PAGI-FastAPI/>

=back

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2026 Mohammad Sajid Anwar.

This program is free software; you can redistribute it and/or modify it under
the terms of the Artistic License (2.0).

=cut

1; # End of PAGI::FastAPI::Middleware::BotProtection
