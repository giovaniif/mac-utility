//! Launch at login: HKCU Run key on Windows, an XDG autostart entry on Linux.

pub fn set(on: bool) -> anyhow::Result<()> {
    let exe = std::env::current_exe()?;
    imp::set(on, &exe)
}

#[cfg(windows)]
mod imp {
    use std::path::Path;
    use std::process::Command;

    pub fn set(on: bool, exe: &Path) -> anyhow::Result<()> {
        let key = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
        let mut cmd = Command::new("reg");
        if on {
            cmd.args(["add", key, "/v", "Utility", "/t", "REG_SZ", "/d", &format!("\"{}\"", exe.display()), "/f"]);
        } else {
            cmd.args(["delete", key, "/v", "Utility", "/f"]);
        }
        cmd.output()?;
        Ok(())
    }
}

#[cfg(not(windows))]
mod imp {
    use std::path::Path;

    pub fn set(on: bool, exe: &Path) -> anyhow::Result<()> {
        let dir = directories::BaseDirs::new()
            .ok_or_else(|| anyhow::anyhow!("no home"))?
            .config_dir()
            .join("autostart");
        let file = dir.join("utility.desktop");
        if on {
            std::fs::create_dir_all(&dir)?;
            std::fs::write(
                &file,
                format!("[Desktop Entry]\nType=Application\nName=Utility\nExec=\"{}\"\nX-GNOME-Autostart-enabled=true\n", exe.display()),
            )?;
        } else if file.exists() {
            std::fs::remove_file(file)?;
        }
        Ok(())
    }
}
