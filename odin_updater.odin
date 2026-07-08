package odin_updater

// Keeps a local Odin compiler installation up to date with the latest
// monthly release from https://github.com/odin-lang/Odin/releases.
//
// Expects the ODIN_PATH environment variable to point at the directory
// that contains the `dist` folder (i.e. the parent of `dist/odin.exe`).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:time/datetime"

REPO :: "odin-lang/Odin"
USER_AGENT :: "odin-updater"

Asset :: struct {
	name:                  string,
	browser_download_url:  string,
}

Release :: struct {
	tag_name: string,
	assets:   []Asset,
}

current_tag :: proc() -> string {
	dt, ok := time.time_to_datetime(time.now())
	assert(ok)
	return fmt.aprintf("dev-%4d-%02d", dt.year, dt.month)
}

read_version_file :: proc(path: string) -> (version: string, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return "", false
	}
	return strings.trim_space(string(data)), true
}

// Runs a command to completion, returning its captured stdout on success.
run :: proc(command: ..string) -> (stdout: string, ok: bool) {
	state, out, err_out, err := os.process_exec(
		{command = command},
		context.allocator,
	)
	defer delete(err_out)
	if err != nil || !state.exited || state.exit_code != 0 {
		delete(out)
		return "", false
	}
	return string(out), true
}

find_windows_asset :: proc(release: Release) -> (Asset, bool) {
	for asset in release.assets {
		lower := strings.to_lower(asset.name, context.temp_allocator)
		if strings.contains(lower, "windows") && strings.has_suffix(lower, ".zip") {
			return asset, true
		}
	}
	return {}, false
}

main :: proc() {
	odin_path, found := os.lookup_env("ODIN_PATH", context.allocator)
	if !found || odin_path == "" {
		fmt.eprintln("ODIN_PATH environment variable is not set.")
		os.exit(1)
	}

	tag := current_tag()
	version_path, _ := filepath.join({odin_path, ".version"}, context.allocator)
	dist_path, _ := filepath.join({odin_path, "dist"}, context.allocator)

	if installed, ok := read_version_file(version_path); ok && installed == tag {
		fmt.printfln("Odin is up to date (%s).", tag)
		return
	}

	// Ask GitHub for this month's release so we don't have to guess the
	// exact windows asset filename (it hasn't always included "amd64").
	api_url := fmt.tprintf("https://api.github.com/repos/%s/releases/tags/%s", REPO, tag)
	body, exec_ok := run("curl.exe", "-fsSL", "-H", fmt.tprintf("User-Agent: %s", USER_AGENT), api_url)
	if !exec_ok {
		fmt.printfln("Could not find a download for %s yet. Nothing to update.", tag)
		return
	}
	defer delete(body)

	release: Release
	if json.unmarshal(transmute([]byte)body, &release) != nil {
		fmt.printfln("Could not find a download for %s yet. Nothing to update.", tag)
		return
	}

	asset, asset_ok := find_windows_asset(release)
	if !asset_ok {
		fmt.printfln("Could not find a windows amd64 download for %s.", tag)
		return
	}

	zip_path, _ := filepath.join({odin_path, asset.name}, context.allocator)
	fmt.printfln("Downloading %s...", asset.name)
	if _, ok := run("curl.exe", "-fsSL", "-o", zip_path, asset.browser_download_url); !ok {
		fmt.printfln("Failed to download %s. Nothing to update.", asset.browser_download_url)
		os.remove(zip_path)
		return
	}

	if os.exists(dist_path) {
		if err := os.remove_all(dist_path); err != nil {
			fmt.eprintfln("Failed to remove old dist folder: %v", err)
			os.exit(1)
		}
	}

	if _, ok := run("tar.exe", "-xf", zip_path, "-C", odin_path); !ok {
		fmt.eprintfln("Failed to extract %s.", zip_path)
		os.exit(1)
	}

	os.remove(zip_path)

	if err := os.write_entire_file_from_string(version_path, tag); err != nil {
		fmt.eprintfln("Failed to write %s: %v", version_path, err)
		os.exit(1)
	}

	fmt.printfln("Updated Odin to %s.", tag)
}
