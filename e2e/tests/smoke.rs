//! Smoke test: the helpers build the paths the real tests will use.

use std::path::Path;

use haotrannas_e2e::workspace_binary;

#[test]
fn workspace_binary_points_into_the_debug_folder() {
    let binary_name = "haotrannas-server";
    let binary_path = workspace_binary(binary_name);
    let expected_file_name = format!("{binary_name}{}", std::env::consts::EXE_SUFFIX);

    assert!(
        binary_path.ends_with(Path::new("debug").join(&expected_file_name)),
        "unexpected path: {}",
        binary_path.display()
    );
}
