<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The single source of medipim product-code knowledge — ported from `CodeRegistry`
 * (lib/ingest/code_registry.ex). Maps each medipim field to {engine scheme, classification}, and
 * provides the bridge-grade axis the over-merge guard uses (national vs barcode vs none).
 */
final class CodeRegistry
{
    /** medipim field name => [engine scheme, classification]. */
    private const REGISTRY = [
        'cnk' => ['cnk', 'identity'],
        'cipOrAcl7' => ['cip_acl7', 'identity'],
        'acl13' => ['acl13', 'identity'],
        'cip13' => ['cip13', 'identity'],
        'pzn' => ['pzn', 'identity'],
        'pznAustria' => ['pzn_austria', 'identity'],
        'sukl' => ['sukl', 'identity'],
        'pdk' => ['pdk', 'identity'],
        'cn' => ['cn', 'identity'],
        'cefip' => ['cefip', 'identity'],
        'nationalCode' => ['national_code', 'identity'],
        'ndc' => ['ndc', 'identity'],
        'hri' => ['hri', 'identity'],
        'pin' => ['pin', 'identity'],
        'fred' => ['fred', 'identity'],
        'zcode' => ['zcode', 'identity'],
        'lppr' => ['lppr', 'identity'],
        'ean' => ['gtin', 'identity'],
        'gtin' => ['gtin', 'identity'],
        'eanGtin8' => ['gtin', 'identity'],
        'eanGtin12' => ['gtin', 'identity'],
        'eanGtin13' => ['gtin', 'identity'],
        'eanGtin14' => ['gtin', 'identity'],
        'undefinedEanGtinCode' => ['gtin', 'identity'],
        'usaGtinCode' => ['gtin', 'identity'],
        'upc10' => ['gtin', 'identity'],
        'upc11' => ['gtin', 'identity'],
        'upc12' => ['gtin', 'identity'],
        'cbId' => ['cb_id', 'external_ref'],
        'ospId' => ['osp_id', 'external_ref'],
        'offisanteId' => ['offisante_id', 'external_ref'],
        'cisCode' => ['cis_code', 'external_ref'],
        'publicPageIdentifier' => ['public_page_identifier', 'external_ref'],
        // AU (gr-sx7.1): artgId is identity but NEVER bridges — one ARTG registration covers
        // many pack sizes (3,807 live ARTG numbers on >1 entity). ClaimMapping marks it shared;
        // bridge grade stays 'none'. snomed* are AMT concept ids — another system's concepts.
        'artgId' => ['artg_id', 'identity'],
        'snomedCtpp' => ['snomed_ctpp', 'external_ref'],
        'snomedTpp' => ['snomed_tpp', 'external_ref'],
        'snomedMpp' => ['snomed_mpp', 'external_ref'],
        'snomedTp' => ['snomed_tp', 'external_ref'],
        'snomedMp' => ['snomed_mp', 'external_ref'],
        'snomedTpuu' => ['snomed_tpuu', 'external_ref'],
        'snomedMpuu' => ['snomed_mpuu', 'external_ref'],
        'supplierReference' => ['supplier_ref', 'external_ref'],
        'isbn13' => ['isbn13', 'identity'],
        'isbn10' => ['isbn10', 'identity'],
        'productId' => ['product_id', 'entity_id'],
        'hsCode' => ['hs_code', 'attribute'],
        'pbs' => ['pbs', 'attribute'],
    ];

    private const DEFAULT_CLASSIFICATION = 'attribute';

    /** Engine-native scheme names not derived from a medipim field. */
    private const EXTRA_ENGINE_SCHEMES = [
        'mpn' => 'mpn',
        'supplier_ref' => 'supplier_ref',
        'ean' => 'ean',
        'upc' => 'upc',
        'cas' => 'cas',
        'unii' => 'unii',
        'substance_id' => 'substance_id',
        'text_id' => 'text_id',
        'asset_id' => 'asset_id',
        'leaflet_id' => 'leaflet_id',
        'uuid' => 'uuid',
    ];

    private const NATIONAL_SCHEMES = [
        'cnk', 'cip_acl7', 'cefip', 'pzn', 'pzn_austria', 'sukl', 'national_code', 'cn',
        'pdk', 'ndc', 'hri', 'pin', 'lppr', 'fred', 'zcode', 'isbn13', 'isbn10',
    ];

    private const BARCODE_SCHEMES = ['gtin', 'acl13', 'cip13'];

    /** Engine scheme for a medipim field; unknown fields stay their raw string. */
    public static function scheme(string $field): string
    {
        return self::REGISTRY[$field][0] ?? $field;
    }

    /** Engine scheme for an engine-native scheme NAME ("cnk" => 'cnk'); unknown names pass through. */
    public static function engineScheme(string $name): string
    {
        if (isset(self::EXTRA_ENGINE_SCHEMES[$name])) {
            return self::EXTRA_ENGINE_SCHEMES[$name];
        }
        foreach (self::REGISTRY as [$scheme, $_class]) {
            if ($scheme === $name) {
                return $scheme;
            }
        }

        return $name;
    }

    /** Classification for a medipim field. */
    public static function classification(string $field): string
    {
        return self::REGISTRY[$field][1] ?? self::DEFAULT_CLASSIFICATION;
    }

    /** Does this medipim field carry a bridging identity code? */
    public static function identityField(string $field): bool
    {
        return self::classification($field) === 'identity';
    }

    /**
     * The set of medipim field names classified 'identity' — the single source of truth the decoder
     * ({@see EnvelopeDecoder}) uses to tell an identity code from an attribute (mirrors the Elixir
     * `CodeRegistry.identity_fields/0`). Returned as a set (field => true) for O(1) membership.
     *
     * @return array<string,true>
     */
    public static function identityFields(): array
    {
        $out = [];
        foreach (self::REGISTRY as $field => [$_scheme, $class]) {
            if ($class === 'identity') {
                $out[$field] = true;
            }
        }

        return $out;
    }

    /** Bridge grade of an engine scheme: 'national' | 'barcode' | 'none'. */
    public static function bridgeGrade(string $scheme): string
    {
        if (in_array($scheme, self::NATIONAL_SCHEMES, true)) {
            return 'national';
        }
        if (in_array($scheme, self::BARCODE_SCHEMES, true)) {
            return 'barcode';
        }

        return 'none';
    }

    public static function nationalGrade(string $scheme): bool
    {
        return self::bridgeGrade($scheme) === 'national';
    }

    public static function barcodeGrade(string $scheme): bool
    {
        return self::bridgeGrade($scheme) === 'barcode';
    }
}
