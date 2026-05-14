Place bundled fallback GIF files in this directory and encode the filename in a
QR code.

Examples:
- `cat.gif`
- `holograms/orb.gif`

The app will first try `assets/<qr-value>` and will also accept a full asset
key such as `assets/cat.gif`.

For phone-imported GIFs, use the in-app library flow instead. Those files are
stored in app-local memory and resolve from `vrgif://local/<gif-id>` payloads.
