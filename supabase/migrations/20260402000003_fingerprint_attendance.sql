-- ============================================================
-- fingerprint_templates table
-- ZKTeco ZK9500 지문 인식기 연동용
-- ============================================================

CREATE TABLE IF NOT EXISTS fingerprint_templates (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  template_data TEXT NOT NULL,
  finger_index  INT NOT NULL DEFAULT 0,
  enrolled_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, finger_index)
);
CREATE INDEX IF NOT EXISTS idx_fingerprint_templates_restaurant
  ON fingerprint_templates (restaurant_id);
CREATE INDEX IF NOT EXISTS idx_fingerprint_templates_user
  ON fingerprint_templates (user_id);
ALTER TABLE fingerprint_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY fingerprint_templates_restaurant_policy ON fingerprint_templates
  USING (restaurant_id = get_user_restaurant_id());
