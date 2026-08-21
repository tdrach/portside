.PHONY: build app install run scan clean dmg release notarize-setup

build:
	swift build

app:
	./build-app.sh

install: app
	-pkill -x Portside
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		pgrep -x Portside >/dev/null || break; \
		sleep 0.5; \
	done
	rm -rf /Applications/Portside.app
	ditto dist/Portside.app /Applications/Portside.app
	open /Applications/Portside.app

release:
	./scripts/release.sh

notarize-setup:
	@echo 'One-time notarization setup:'
	@echo
	@echo '  xcrun notarytool store-credentials portside \'
	@echo '    --apple-id <your-apple-id> --team-id <your-team-id>'
	@echo
	@echo 'Needs an app-specific password from appleid.apple.com'
	@echo '(Sign-In and Security > App-Specific Passwords), or use an'
	@echo 'App Store Connect API key with --key/--key-id/--issuer.'

dmg: app
	rm -rf dist/dmg dist/Portside.dmg
	mkdir -p dist/dmg
	ditto dist/Portside.app dist/dmg/Portside.app
	ln -s /Applications dist/dmg/Applications
	hdiutil create -volname Portside -srcfolder dist/dmg -ov -format UDZO dist/Portside.dmg
	rm -rf dist/dmg

run:
	swift run Portside

scan:
	swift run Portside --scan

clean:
	rm -rf .build dist
