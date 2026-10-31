import 'package:supabase_flutter/supabase_flutter.dart';

/// Resolve after bootstrap, without importing the app/router/widget graph.
SupabaseClient get supabase => Supabase.instance.client;
