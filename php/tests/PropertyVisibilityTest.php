<?php

declare(strict_types=1);

namespace Ingot\Tests;

use PHPUnit\Framework\TestCase;

/**
 * Architecture guard: no class in the package exposes public MUTABLE state. Every declared
 * property must be `private` or `readonly` — the value objects deliberately use public readonly
 * properties (`$claim->kind`), which is safe because they cannot be written; anything writable
 * stays private behind methods (e.g. InMemoryClaimStore's tables). A new class that adds a
 * public writable property fails here, not in review.
 */
final class PropertyVisibilityTest extends TestCase
{
    public function test_every_property_is_private_or_readonly(): void
    {
        $violations = [];

        foreach (self::sourceClasses() as $class) {
            $reflection = new \ReflectionClass($class);
            foreach ($reflection->getProperties() as $property) {
                if ($property->getDeclaringClass()->getName() !== $class) {
                    continue;
                }
                if ($property->isPrivate() || $property->isReadOnly()) {
                    continue;
                }
                $violations[] = $class.'::$'.$property->getName();
            }
        }

        self::assertSame([], $violations, 'public/protected mutable properties found — make them private or readonly');
    }

    /** @return list<class-string> every class/interface declared under src/ */
    private static function sourceClasses(): array
    {
        $src = realpath(__DIR__.'/../src');
        $classes = [];

        $files = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($src));
        foreach ($files as $file) {
            if (!$file->isFile() || $file->getExtension() !== 'php') {
                continue;
            }
            $relative = substr($file->getPathname(), strlen($src) + 1, -4);
            $classes[] = 'Ingot\\'.str_replace(DIRECTORY_SEPARATOR, '\\', $relative);
        }

        sort($classes);
        self::assertNotEmpty($classes, 'no classes found under src/ — path wrong?');

        return $classes;
    }
}
