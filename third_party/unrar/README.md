# UnRAR

ZIPP liest RAR-Archive mit dem offiziellen UnRAR-Quellcode von Alexander Roshal.
Der Code wird über die Rust-Crate [`unrar_sys`](https://crates.io/crates/unrar_sys)
eingebunden (siehe `core/zipp-core/Cargo.toml`), nicht in diesem Repository kopiert.

Er steht unter der **UnRAR-Lizenz** (`license.txt` in diesem Ordner), nicht unter MIT/Apache:

- Entpacken von RAR-Archiven ist erlaubt, auch in kostenloser und Open-Source-Software.
- Der Code darf **nicht** verwendet werden, um den RAR-Kompressionsalgorithmus nachzubauen.
  Deshalb kann ZIPP keine RAR-Archive erstellen.
- Die UnRAR-Lizenz ist nicht GPL-kompatibel. ZIPP steht deshalb unter MIT oder Apache-2.0.
