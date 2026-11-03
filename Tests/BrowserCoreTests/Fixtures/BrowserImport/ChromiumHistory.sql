CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER);
CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER, transition INTEGER);
INSERT INTO urls VALUES(1, 'https://history.example.test/', 'History page', 2, 13344473602000000);
INSERT INTO visits VALUES(1, 1, 13344473601000000, 0);
INSERT INTO visits VALUES(2, 1, 13344473602000000, 0);
INSERT INTO visits VALUES(3, 1, 0, 0);
