// swift-tools-version: 6.0
import PackageDescription

// `Vendor/libwebp` holds a pre-built libwebp 1.6.0 (libwebp.a + libwebpdemux.a) with the headers it
// was built from, as **fat** static libraries carrying both an arm64 and an x86_64 slice — so one
// tree can produce both the Apple Silicon build and the Intel build. It is vendored rather than
// taken from Homebrew at build time so that the shipped bundle is self-contained and so that a
// build does not change meaning when somebody upgrades the formula. See
// Vendor/libwebp/README.vendor.md for provenance, hashes, and how the x86_64 slice was produced.
let vendorWebP = "Vendor/libwebp"

let package = Package(
    name: "Picnido",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Picnido", targets: ["Picnido"])
    ],
    targets: [
        .target(
            name: "CWebP",
            path: "Sources/CWebP",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../\(vendorWebP)/include")
            ],
            linkerSettings: [
                // Order matters: ld64 resolves a static library in a single pass, so the
                // dependant has to come before the dependency. libwebpdemux calls into libwebp
                // and never the other way round.
                .unsafeFlags(["-L\(vendorWebP)/lib", "-lwebpdemux", "-lwebp"])
            ]
        ),
        .executableTarget(
            name: "Picnido",
            dependencies: ["CWebP"],
            path: "Sources/Picnido",
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
