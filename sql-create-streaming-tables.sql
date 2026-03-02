CREATE TABLE employees.departments_streaming AS SELECT * FROM employees.departments WHERE 1=0;
CREATE TABLE employees.employees_streaming AS SELECT * FROM employees.employees WHERE 1=0;
CREATE TABLE employees.dept_emp_streaming AS SELECT * FROM employees.dept_emp WHERE 1=0;
CREATE TABLE employees.dept_manager_streaming AS SELECT * FROM employees.dept_manager WHERE 1=0;
CREATE TABLE employees.salaries_streaming AS SELECT * FROM employees.salaries WHERE 1=0;
CREATE TABLE employees.titles_streaming AS SELECT * FROM employees.titles WHERE 1=0;