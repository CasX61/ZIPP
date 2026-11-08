//! Erzeugt die Swift-Bindings für zipp-ffi (siehe scripts/build-core.sh).
fn main() {
    uniffi::uniffi_bindgen_swift();
}
