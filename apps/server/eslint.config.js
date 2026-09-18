// What the linter is for here: the things tsc does not say. Type-aware rules are on, because
// the one that matters most for a Fastify server -- no-floating-promises -- needs them.
//
// No formatter. shellcheck does not format the bash side either; a formatter is a separate
// decision and not one this package needs to make.

import js from '@eslint/js'
import tseslint from 'typescript-eslint'

export default tseslint.config(
    { ignores: ['dist/'] },
    js.configs.recommended,
    {
        files: ['**/*.ts'],
        extends: [tseslint.configs.recommendedTypeChecked],
        languageOptions: {
            parserOptions: {
                projectService: true,
                tsconfigRootDir: import.meta.dirname,
            },
        },
        rules: {
            // node:test's `test`, `before` and `after` return promises that the runner already
            // owns; awaiting them is wrong, and `void`-ing every call would bury the rule's
            // real finding -- an un-awaited request or `app.close()` -- in noise.
            '@typescript-eslint/no-floating-promises': [
                'error',
                {
                    allowForKnownSafeCalls: [
                        {
                            from: 'package',
                            package: 'node:test',
                            name: ['after', 'before', 'describe', 'it', 'test'],
                        },
                    ],
                },
            ],
        },
    },
    {
        // This file itself: plain JavaScript, outside tsconfig.json, so the type-aware rules
        // have no program to read it from.
        files: ['**/*.js'],
        extends: [tseslint.configs.disableTypeChecked],
    },
)
