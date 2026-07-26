<?php

declare(strict_types=1);

/**
 * Split an ALTER TABLE clause list on top-level commas that precede ADD/DROP.
 *
 * Usage: php util/migration_schema_split_alter.php
 * Reads the ALTER TABLE body (everything after the table name) from stdin.
 */

$rest = stream_get_contents(STDIN);
if ($rest === false) {
    exit(0);
}
$rest = trim($rest);

$parts = [];
$buf = '';
$depth = 0;
$len = strlen($rest);

for ($i = 0; $i < $len; $i++) {
    $ch = $rest[$i];
    if ($ch === '(') {
        $depth++;
        $buf .= $ch;
        continue;
    }
    if ($ch === ')') {
        $depth = max(0, $depth - 1);
        $buf .= $ch;
        continue;
    }
    if ($ch === ',' && $depth === 0) {
        $next = ltrim(substr($rest, $i + 1));
        if (preg_match('/^(ADD|DROP)\b/i', $next) === 1) {
            $parts[] = trim($buf);
            $buf = '';
            continue;
        }
    }
    $buf .= $ch;
}

if (trim($buf) !== '') {
    $parts[] = trim($buf);
}

foreach ($parts as $p) {
    echo $p, "\n";
}
