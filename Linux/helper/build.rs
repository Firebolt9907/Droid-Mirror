// Compiles the shared, portable AOA (USB accessory) transport from Native/.
fn main() {
    let source = "../../Native/UsbAccessoryTransport.c";
    println!("cargo:rerun-if-changed={source}");
    let usb = pkg_config::Config::new().probe("libusb-1.0").expect("libusb-1.0 development files are required");
    let mut build = cc::Build::new();
    build.file(source).std("c11").define("_GNU_SOURCE", None).warnings(false);
    for path in &usb.include_paths {
        build.include(path);
        // The source includes <libusb-1.0/libusb.h>; also allow the parent directory.
        if let Some(parent) = path.parent() {
            build.include(parent);
        }
    }
    build.compile("droidmirror_usb");
}
