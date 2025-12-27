# Script tu dong dong goi va day len Firebase Hosting
# 1. Build APK
Write-Host "--- Dang dong goi APK (Split per ABI) ---"
flutter build apk --release --split-per-abi

# 2. Copy file vao thu muc public
Write-Host "--- Dang chuan bi thu muc public ---"
if (!(Test-Path "firebase_hosting/public")) { New-Item -ItemType Directory -Path "firebase_hosting/public" }

Copy-Item "build/app/outputs/flutter-apk/app-arm64-v8a-release.apk" "firebase_hosting/public/idmav-arm64.apk" -Force
Copy-Item "build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk" "firebase_hosting/public/idmav-armv7.apk" -Force
Copy-Item "version.json" "firebase_hosting/public/version.json" -Force

# Tao file index.html trong de Firebase Hosting khong bao loi
if (!(Test-Path "firebase_hosting/public/index.html")) {
    "<html><body><h1>iDMAV App Updates</h1></body></html>" | Out-File -FilePath "firebase_hosting/public/index.html" -Encoding utf8
}

# 3. Deploy
Write-Host "--- Dang kiem tra dang nhap Firebase ---"
npx firebase projects:list
if ($LASTEXITCODE -ne 0) {
    Write-Host "!!! Ban chua dang nhap Firebase. Vui long chay lenh: npx firebase login !!!"
    exit
}

Write-Host "--- Dang day len Firebase Hosting ---"
npx firebase deploy --only hosting

Write-Host "--- HOAN TAT ---"
