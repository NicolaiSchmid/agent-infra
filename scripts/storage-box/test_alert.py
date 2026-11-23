import unittest

import alert


class FixedMessageTest(unittest.TestCase):
    def test_executor_db_unit_names_are_the_only_free_value(self):
        title, message = alert.fixed_message(['executor-db', 'executor-db-june-prod-health.service'])
        self.assertEqual(title, 'Executor database failed')
        self.assertIn('executor-db-june-prod-health.service', message)
        alert.fixed_message(['executor-db', 'executor-db-june-dev-backup.service'])
        for unit in ['executor-db-june-prod.service', 'executor-db-x-health.service; rm', 'hosted-runner-june-prod.service']:
            with self.assertRaises(SystemExit):
                alert.fixed_message(['executor-db', unit])

    def test_default_and_hosted_runner_unchanged(self):
        self.assertEqual(alert.fixed_message([]), alert.STALE)
        self.assertEqual(alert.fixed_message(['hosted-runner', 'hosted-runner-june-dev.service'])[0], 'Hosted runner failed')


if __name__ == '__main__':
    unittest.main()
