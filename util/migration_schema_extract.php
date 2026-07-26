<?php

declare(strict_types=1);

/**
 * Extract $this->addSql('...') string literals from a migration's up() method.
 *
 * Usage: php util/migration_schema_extract.php path/to/Version….php
 * Prints one normalized SQL statement per line on stdout.
 */

$file = $argv[1] ?? '';
if ($file === '' || !is_readable($file)) {
    fwrite(STDERR, "Usage: php migration_schema_extract.php <MigrationFile.php>\n");
    exit(2);
}

$src = file_get_contents($file);
if ($src === false || $src === '') {
    exit(0);
}

if (!preg_match('/function\s+up\s*\(/', $src, $m, PREG_OFFSET_CAPTURE)) {
    exit(0);
}

$rest = substr($src, $m[0][1]);
if (preg_match('/\n\s*(?:public|protected|private)\s+function\s+/', $rest, $m2, PREG_OFFSET_CAPTURE, 1)) {
    $up = substr($rest, 0, $m2[0][1]);
} else {
    $up = $rest;
}

$re = '/\$this\s*->\s*addSql\s*\(\s*(?:"((?:\\\\.|[^"\\\\])*)"|\'((?:\\\\.|[^\'\\\\])*)\')/';
if (!preg_match_all($re, $up, $matches, PREG_SET_ORDER)) {
    exit(0);
}

foreach ($matches as $hit) {
    $sql = $hit[1] !== '' ? $hit[1] : $hit[2];
    $sql = stripcslashes($sql);
    $sql = preg_replace('/\s+/', ' ', trim($sql)) ?? '';
    if ($sql !== '') {
        echo $sql, "\n";
    }
}
