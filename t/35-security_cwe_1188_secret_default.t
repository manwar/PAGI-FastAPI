#!/usr/bin/env perl

use v5.38;
use Test::More;
use Test::Fatal qw(exception);

use PAGI::FastAPI::BotProtection::ProofOfWork;

# 1. Test constructor failure when 'secret' is omitted entirely
like(
    exception { PAGI::FastAPI::BotProtection::ProofOfWork->new() },
    qr/Required parameter 'secret' is missing/,
    'Fails when secret parameter is missing'
);

# 2. Test constructor failure when 'secret' is explicitly undef (e.g. unset %ENV)
like(
    exception { PAGI::FastAPI::BotProtection::ProofOfWork->new(secret => undef) },
    qr/ProofOfWork: 'secret' parameter must be defined and non-empty in production/,
    'Fails when secret is explicitly undef'
);

# 3. Test constructor failure when 'secret' is an empty string
like(
    exception { PAGI::FastAPI::BotProtection::ProofOfWork->new(secret => '') },
    qr/ProofOfWork: 'secret' parameter must be defined and non-empty in production/,
    'Fails when secret is an empty string'
);

# 4. Test successful instantiation with a valid secret
my $pow;
is(
    exception {
        $pow = PAGI::FastAPI::BotProtection::ProofOfWork->new(
            secret     => 'valid_secure_secret_key',
            difficulty => 3,
            ttl        => 300,
        );
    },
    undef,
    'Instantiates successfully with valid secret'
);

# 5. Test challenge creation and verification with the configured secret
my $client_ip = '192.168.1.50';
my $challenge_data = $pow->create_challenge($client_ip);

is(ref $challenge_data, 'HASH', 'create_challenge returns a hash ref');
ok(defined $challenge_data->{challenge}, 'Challenge token generated');

# Solve PoW locally to test verify()
my $nonce = 0;
my $target = '0' x 3;
$nonce++ while index(Digest::SHA::sha256_hex("$challenge_data->{challenge}:$nonce"), $target) != 0;

ok(
    $pow->verify($challenge_data->{challenge}, $nonce, $client_ip),
    'Validates PoW solution successfully with non-empty secret'
);

# 6. Test forged diff=0 challenge with arbitrary signature fails verification
my $forged_challenge = "127.0.0.1|9999999999|0|fake_signature_12";
ok(
    !$pow->verify($forged_challenge, "any_nonce", "127.0.0.1"),
    'Forged zero-difficulty challenge fails verification due to invalid HMAC signature'
);

done_testing;
