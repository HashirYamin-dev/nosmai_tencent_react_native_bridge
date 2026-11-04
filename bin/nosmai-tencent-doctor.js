#!/usr/bin/env node
/*
 * Read-only setup checker for apps that use react-native-nosmai-tencent-bridge.
 * It never modifies files. Run from the React Native app root:
 *
 *   npx nosmai-tencent-doctor            # checks the current directory
 *   npx nosmai-tencent-doctor ../MyApp   # checks another app
 *
 * Exit code 1 when a blocking problem is found.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(process.argv[2] || process.cwd());
let errors = 0;
let warnings = 0;

const ok = msg => console.log(`  ✔ ${msg}`);
const warn = msg => { warnings++; console.log(`  ⚠ ${msg}`); };
const fail = msg => { errors++; console.log(`  ✖ ${msg}`); };
const section = title => console.log(`\n${title}`);

const read = rel => {
  try { return fs.readFileSync(path.join(root, rel), 'utf8'); } catch (_) { return null; }
};
const exists = rel => fs.existsSync(path.join(root, rel));
const list = rel => {
  try { return fs.readdirSync(path.join(root, rel)); } catch (_) { return []; }
};

console.log(`Nosmai Tencent bridge doctor — checking ${root}`);

// ---------------------------------------------------------------- package.json
section('JavaScript dependencies');
const pkgText = read('package.json');
if (!pkgText) {
  fail('package.json not found. Run this from your React Native app root.');
  process.exit(1);
}
let pkg = {};
try { pkg = JSON.parse(pkgText); } catch (_) { fail('package.json is not valid JSON'); }
const deps = Object.assign({}, pkg.devDependencies, pkg.dependencies);

const rn = deps['react-native'];
if (!rn) fail('react-native is not a dependency');
else if (/0\.81\./.test(rn)) ok(`react-native ${rn}`);
else warn(`react-native ${rn} — this bridge is tested with 0.81.5`);

if (deps['@nosmai/react-native-effects-sdk']) ok(`@nosmai/react-native-effects-sdk ${deps['@nosmai/react-native-effects-sdk']}`);
else fail('@nosmai/react-native-effects-sdk is missing (npm install @nosmai/react-native-effects-sdk@2.0.1)');

if (deps['react-native-nosmai-tencent-bridge']) ok('react-native-nosmai-tencent-bridge installed');
else fail('react-native-nosmai-tencent-bridge is not in package.json');

if (deps.expo) warn('Expo detected — Expo Go is not supported; use a custom native development build');

// --------------------------------------------------------------------- Android
section('Android');
if (!exists('android')) {
  warn('android/ folder not found — skipping Android checks');
} else {
  const props = read('android/gradle.properties') || '';
  if (/^\s*newArchEnabled\s*=\s*true\s*$/m.test(props)) ok('newArchEnabled=true');
  else fail('android/gradle.properties must contain newArchEnabled=true');

  const gradleFiles = ['android/build.gradle', 'android/build.gradle.kts',
    'android/app/build.gradle', 'android/app/build.gradle.kts'];
  let minSdk = null;
  for (const file of gradleFiles) {
    const text = read(file);
    const m = text && text.match(/minSdk(?:Version)?\s*(?:=|\s)\s*(\d+)/);
    if (m) { minSdk = Number(m[1]); break; }
  }
  if (minSdk === null) warn('Could not find minSdkVersion; it must be 24 or higher');
  else if (minSdk >= 24) ok(`minSdkVersion ${minSdk}`);
  else fail(`minSdkVersion ${minSdk} is too low; set it to 24 or higher`);

  const appGradle = read('android/app/build.gradle') || read('android/app/build.gradle.kts') || '';
  const appId = appGradle.match(/applicationId\s*(?:=\s*)?["']([^"']+)["']/);
  if (appId) ok(`applicationId ${appId[1]} — your Android Nosmai license must be issued for this exact ID`);
  else warn('Could not read applicationId; it must match your Android Nosmai license');

  const aars = list('android/app/libs').filter(f => /nosmai.*\.aar$/i.test(f));
  if (aars.length > 1) fail(`More than one Nosmai AAR in android/app/libs (${aars.join(', ')}); keep exactly one`);
  else if (aars.length === 1) ok(`Nosmai AAR: android/app/libs/${aars[0]}`);
  else warn('No Nosmai AAR in android/app/libs — fine if Gradle resolves com.nosmai:nosmai-sdk:3.0.7; otherwise follow the Nosmai RN install guide');

  ok('CAMERA, RECORD_AUDIO and INTERNET permissions are merged from the bridge manifest');
}

// ------------------------------------------------------------------------- iOS
section('iOS');
if (!exists('ios')) {
  warn('ios/ folder not found — skipping iOS checks');
} else {
  const podfile = read('ios/Podfile') || '';
  const platform = podfile.match(/platform\s*:ios\s*,\s*['"]?([\w.]+)['"]?/);
  if (!platform) warn('Could not read the iOS platform from ios/Podfile; it must be iOS 15 or higher');
  else if (platform[1] === 'min_ios_version_supported') ok('Podfile platform: React Native default (iOS 15.1 for RN 0.81)');
  else if (parseFloat(platform[1]) >= 15) ok(`Podfile platform: iOS ${platform[1]}`);
  else fail(`Podfile platform iOS ${platform[1]} is too low; use 15.0 or higher`);

  const plists = list('ios')
    .filter(dir => !['Pods', 'build'].includes(dir))
    .map(dir => path.join('ios', dir, 'Info.plist'))
    .filter(exists);
  if (plists.length === 0) {
    warn('No app Info.plist found under ios/<AppName>/');
  } else {
    for (const plist of plists) {
      const text = read(plist) || '';
      for (const key of ['NSCameraUsageDescription', 'NSMicrophoneUsageDescription']) {
        if (text.includes(`<key>${key}</key>`)) ok(`${plist}: ${key}`);
        else fail(`${plist} is missing ${key}`);
      }
    }
  }

  if (!exists('ios/Pods')) {
    warn('ios/Pods not found — run: cd ios && pod install');
  } else {
    const lock = read('ios/Podfile.lock') || '';
    for (const pod of ['NosmaiCameraSDK', 'TXLiteAVSDK_Professional', 'react-native-nosmai-tencent-bridge']) {
      if (lock.includes(`- ${pod}`)) ok(`Pod installed: ${pod}`);
      else fail(`Pod ${pod} not in Podfile.lock — run: cd ios && pod install`);
    }
  }
  ok('Reminder: test on a physical iPhone; the Bundle ID must match your iOS Nosmai license');
}

// --------------------------------------------------------------------- Summary
console.log(`\n${errors} problem(s), ${warnings} warning(s).`);
if (errors === 0) console.log('Native configuration looks ready. Rebuild the native app after any change.');
process.exit(errors > 0 ? 1 : 0);
