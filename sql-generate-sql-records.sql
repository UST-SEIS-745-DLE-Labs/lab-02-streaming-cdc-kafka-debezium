INSERT INTO employees.departments_streaming SELECT * FROM employees.departments;
INSERT INTO employees.dept_manager_streaming SELECT * FROM employees.dept_manager;
INSERT INTO employees.employees_streaming SELECT * FROM employees.employees
    WHERE emp_no IN (SELECT emp_no FROM employees.dept_manager);
INSERT INTO employees.employees_streaming SELECT * FROM employees.employees
    WHERE emp_no NOT IN (SELECT emp_no FROM employees.dept_manager_streaming)
    AND emp_no IN (SELECT emp_no FROM (
      SELECT emp_no, row_number() OVER (ORDER BY hire_date DESC, emp_no DESC) AS rn FROM employees.employees) AS q1
      WHERE q1.rn < 1000);
INSERT INTO employees.dept_emp_streaming SELECT * FROM employees.dept_emp
    WHERE emp_no IN (SELECT emp_no FROM employees.employees_streaming);
INSERT INTO employees.salaries_streaming SELECT * FROM employees.salaries
    WHERE emp_no IN (SELECT emp_no FROM employees.employees_streaming);
INSERT INTO employees.titles_streaming SELECT * FROM employees.titles
    WHERE emp_no IN (SELECT emp_no FROM employees.employees_streaming);
    
UPDATE employees.salaries_streaming
SET salary=salary*1.1
WHERE to_date > SYSDATE();

DELETE FROM employees.employees_streaming
WHERE emp_no IN (SELECT emp_no FROM (
      SELECT emp_no, row_number() OVER (ORDER BY hire_date DESC, emp_no DESC) AS rn FROM employees.employees_streaming) AS q1
      WHERE q1.rn < 10);