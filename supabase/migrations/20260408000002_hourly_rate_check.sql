-- MD1: staff_wage_configs.hourly_rate must be positive when set
ALTER TABLE staff_wage_configs
  ADD CONSTRAINT chk_hourly_rate CHECK (hourly_rate IS NULL OR hourly_rate > 0);
