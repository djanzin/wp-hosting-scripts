<?php
/**
 * FluentSMTP-Verbindung anlegen/aktualisieren (Amazon SES via SMTP).
 * Aufruf: wp eval-file fluentsmtp-set.php
 * Alle Werte kommen aus der Umgebung (FSMTP_*), nichts aus argv.
 * Gibt NIE Credential-Werte aus — nur Status, Connection-Key und Laengen.
 */

$sender = getenv('FSMTP_SENDER');
$name   = getenv('FSMTP_NAME');
$host   = getenv('FSMTP_HOST');
$port   = getenv('FSMTP_PORT');
$user   = getenv('FSMTP_USER');
$pass   = getenv('FSMTP_PASS');

foreach (['FSMTP_SENDER' => $sender, 'FSMTP_NAME' => $name, 'FSMTP_HOST' => $host,
          'FSMTP_PORT' => $port, 'FSMTP_USER' => $user, 'FSMTP_PASS' => $pass] as $k => $v) {
    if (!is_string($v) || $v === '') {
        WP_CLI::error("Env $k fehlt oder ist leer.");
    }
}

if (!is_email($sender)) {
    WP_CLI::error('FSMTP_SENDER ist keine gueltige E-Mail-Adresse.');
}

if (!function_exists('fluentMailSetSettings')) {
    WP_CLI::error('FluentSMTP ist nicht geladen (fluent-smtp aktiv?).');
}

$settingsModel = new \FluentMail\App\Models\Settings();

$inputs = [
    'connection_key' => '',
    'valid_senders'  => [],
    'connection'     => [
        'provider'         => 'smtp',
        'sender_name'      => $name,
        'sender_email'     => $sender,
        'force_from_name'  => 'no',
        'force_from_email' => 'yes',
        'return_path'      => 'yes',
        'host'             => $host,
        'port'             => $port,
        'auth'             => 'yes',
        'username'         => $user,
        'password'         => $pass,
        'auto_tls'         => 'yes',
        'encryption'       => 'tls',
        'key_store'        => 'db',
    ],
];

$settingsModel->store($inputs);

// Verifikation aus der gespeicherten (entschluesselten) Sicht — ohne Werte.
$saved = fluentMailGetSettings([], false);
$key   = md5($sender);

if (empty($saved['connections'][$key])) {
    WP_CLI::error('Connection wurde nicht gespeichert.');
}

$ps = $saved['connections'][$key]['provider_settings'];
$ok = ($ps['username'] === $user && $ps['password'] === $pass);

WP_CLI::log('connection_key=' . $key);
WP_CLI::log('sender=' . $ps['sender_email'] . ' host=' . $ps['host'] . ':' . $ps['port']);
WP_CLI::log('user_len=' . strlen($ps['username']) . ' pass_len=' . strlen($ps['password']));
WP_CLI::log('default_connection=' . (isset($saved['misc']['default_connection']) ? $saved['misc']['default_connection'] : ''));
WP_CLI::log('roundtrip=' . ($ok ? 'MATCH' : 'MISMATCH'));

if (!$ok) {
    WP_CLI::error('Roundtrip-Vergleich fehlgeschlagen.');
}

WP_CLI::success('FluentSMTP-Verbindung gespeichert.');
