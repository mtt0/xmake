add_rules("mode.debug", "mode.release")

target("${TARGETNAME}")
    add_rules("xcode.bundle")
    add_files("src/*.mm")
    add_headerfiles("src/*.h")
    add_installfiles("src/Info.plist")
    --set_values("xcode.codesign_identity", "Apple Development: xxx@gmail.com (T3NA4MRVPU)")

${FAQ}