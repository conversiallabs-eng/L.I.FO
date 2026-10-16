-- Migration: Add city_uf to user_profiles table and reload PostgREST schema cache
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS city_uf TEXT;
NOTIFY pgrst, 'reload schema';
