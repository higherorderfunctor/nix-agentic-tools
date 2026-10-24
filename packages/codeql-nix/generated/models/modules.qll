/** Generated from modules.json; do not edit. */
predicate helper(string libHash, string modelHash, string exportIdentity, string kind, string argumentSpecJson) {
 libHash = "sha256-IoNisKcGbUjdd45qCqywGMCYmZ5EnkxezvLII0FWwNA=" and modelHash = "sha256:b4c818374d8f3d9790a32f2b013f520803d0ffa041d04847ac4b629c63ddfbea" and (
 exportIdentity = "module-helper:sha256:aedfab29533a9f6a75be2547e31ee552b9a44eb1748d5179e7a0eabc879c67f8" and kind = "order" and argumentSpecJson = "{\"arity\":1,\"content\":0}"
 or exportIdentity = "module-helper:sha256:5b8c1556706731fe5a13e70ae63ddd915c4c5061bc31d1ce782f3a08f425c8a0" and kind = "order" and argumentSpecJson = "{\"arity\":1,\"content\":0}"
 or exportIdentity = "module-helper:sha256:1c097d9ac6646ee0f279fa5fffdcaa46b233cb785b10df004377b312038c94aa" and kind = "override" and argumentSpecJson = "{\"arity\":1,\"content\":0}"
 or exportIdentity = "module-helper:sha256:de683cbf03895e77f550344b115eef3c4787d29a2a47fc90b8f01b165c13258e" and kind = "override" and argumentSpecJson = "{\"arity\":1,\"content\":0}"
 or exportIdentity = "module-helper:sha256:d6d69ac79925550f1993826d9a9ca95c6bb1bf1d865b02afcc5c757d839789d0" and kind = "if" and argumentSpecJson = "{\"arity\":2,\"content\":1}"
 or exportIdentity = "module-helper:sha256:37fa83acab42f1440713fbfd58457a0ccbc2cad0f55d9d87bacc740f057e36cd" and kind = "merge" and argumentSpecJson = "{\"arity\":1,\"content\":0}"
 or exportIdentity = "module-helper:sha256:5c6a0b5b4a96d2a38b621a36b13fb3dca430fc99c342ddcc219aa8a4b8bd5203" and kind = "order" and argumentSpecJson = "{\"arity\":2,\"content\":1}"
 or exportIdentity = "module-helper:sha256:a4bb1e1fef0bf8ec4afeb0fefdcc42c76238719a6cef9f87aed2ad6963b08058" and kind = "override" and argumentSpecJson = "{\"arity\":2,\"content\":1}")
}
predicate exported(string name, string identity) {
 name = "mkAfter" and identity = "module-helper:sha256:aedfab29533a9f6a75be2547e31ee552b9a44eb1748d5179e7a0eabc879c67f8"
 or name = "mkBefore" and identity = "module-helper:sha256:5b8c1556706731fe5a13e70ae63ddd915c4c5061bc31d1ce782f3a08f425c8a0"
 or name = "mkDefault" and identity = "module-helper:sha256:1c097d9ac6646ee0f279fa5fffdcaa46b233cb785b10df004377b312038c94aa"
 or name = "mkForce" and identity = "module-helper:sha256:de683cbf03895e77f550344b115eef3c4787d29a2a47fc90b8f01b165c13258e"
 or name = "mkIf" and identity = "module-helper:sha256:d6d69ac79925550f1993826d9a9ca95c6bb1bf1d865b02afcc5c757d839789d0"
 or name = "mkMerge" and identity = "module-helper:sha256:37fa83acab42f1440713fbfd58457a0ccbc2cad0f55d9d87bacc740f057e36cd"
 or name = "mkOrder" and identity = "module-helper:sha256:5c6a0b5b4a96d2a38b621a36b13fb3dca430fc99c342ddcc219aa8a4b8bd5203"
 or name = "mkOverride" and identity = "module-helper:sha256:a4bb1e1fef0bf8ec4afeb0fefdcc42c76238719a6cef9f87aed2ad6963b08058"
}
predicate constant(string name, string priority) {
 name = "mkAfter" and priority = "1500"
 or name = "mkBefore" and priority = "500"
 or name = "mkDefault" and priority = "1000"
 or name = "mkForce" and priority = "50"
 or name = "ordinaryOverridePriority" and priority = "100"
}
predicate builtinFingerprint(string value) { value = "sha256:7d63194ef2974a41721381c1b010dd4f990f18a12b91e26c3c19d92699a4c2bf" }
predicate bundleFingerprint(string value) { value = "sha256:b4c818374d8f3d9790a32f2b013f520803d0ffa041d04847ac4b629c63ddfbea" }
predicate libraryFingerprint(string value) { value = "sha256-IoNisKcGbUjdd45qCqywGMCYmZ5EnkxezvLII0FWwNA=" }
