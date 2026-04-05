DROP POLICY IF EXISTS office_payroll_reviews_admin_update ON office_payroll_reviews;

CREATE POLICY office_payroll_reviews_office_update
ON office_payroll_reviews
FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM office_user_profiles oup
    WHERE oup.auth_id = auth.uid()
      AND oup.is_active = true
      AND oup.account_level IN ('super_admin', 'platform_admin', 'office_admin', 'brand_admin')
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM office_user_profiles oup
    WHERE oup.auth_id = auth.uid()
      AND oup.is_active = true
      AND oup.account_level IN ('super_admin', 'platform_admin', 'office_admin', 'brand_admin')
  )
);
