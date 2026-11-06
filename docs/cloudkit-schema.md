# CloudKit schema changes

The Production CloudKit schema is additive-only: add fields or record types,
never rename or remove deployed schema. After an additive change:

1. Temporarily pin the macOS Debug entitlement to `Development`.
2. Run `just bootstrap-cloudkit-schema`, which uses
   `Shared/Core/AppCloudKitSchemaBootstrap.swift`. It installs without a normal
   launch, so real data cannot sync into Development.
3. Deploy only the reviewed additive diff in CloudKit Console.
4. Verify that both environments' exports match.
5. Restore the `Production` pin and run `just install-mac`.

Never leave a Development-pinned app installed.
