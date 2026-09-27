default:
    @just --list
bump-all:
    scripts/bump-up-version.sh
bump app:
    scripts/bump-up-version.sh {{ app }}
