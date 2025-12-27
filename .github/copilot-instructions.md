# AI Assistant Instructions for idmav_app

## Project Overview
This is a Flutter mobile application implementing a simple login system with Bluetooth capabilities. The app follows a basic route-based navigation pattern with stateful widget management.

## Key Architecture Points

### Navigation Flow
- App entry: `lib/main.dart` defines routes
- Initial route: `/login` (LoginPage)
- Post-authentication: `/home` (HomePage)
- Navigation uses MaterialApp's named routes system

### State Management
- Uses Flutter's built-in StatefulWidget pattern
- Persistence handled via shared_preferences plugin
- Authentication state stored locally with SharedPreferences

### Authentication Pattern
```dart
// Example from login_page.dart
if (_usernameController.text == 'Admin' && _passwordController.text == '4444') {
  // Credentials are valid
  // Store if remember me is checked
  Navigator.pushReplacementNamed(context, '/home');
}
```

### Key Dependencies
- shared_preferences: Local storage for auth state
- flutter_blue_plus: Bluetooth LE functionality
- flutter_lints: Standard Flutter linting rules

## Development Workflow

### Environment Setup
1. Requires Flutter SDK ^3.9.2
2. Uses standard Flutter project structure
3. Multi-platform support (iOS, Android, Web, Desktop)

### Common Commands
```bash
# Get dependencies
flutter pub get

# Run app in debug mode
flutter run

# Build release version
flutter build <platform>  # where platform is ios/android/web
```

### Testing
- Widget tests located in `test/widget_test.dart`
- Run tests with: `flutter test`

## Project Conventions

### UI Patterns
- Material Design based theming
- Consistent padding: 24.0 logical pixels
- Card-based layout with shadow effects
- Primary color: Colors.blue
- Standard elevation: 0 for AppBar

### State Management Patterns
- Authentication state persisted in SharedPreferences
- Remember Me functionality for credentials
- Logout clears all stored credentials

## Common Gotchas
- Remember to handle SharedPreferences operations asynchronously
- Navigation uses pushReplacementNamed to prevent back navigation after login/logout
- Bluetooth functionality requires appropriate platform permissions

## Directory Structure Notes
- `lib/`: Core application code
  - `main.dart`: App entry and route definitions
  - `login_page.dart`: Authentication handling
  - `home_page.dart`: Main app interface
- `test/`: Test files