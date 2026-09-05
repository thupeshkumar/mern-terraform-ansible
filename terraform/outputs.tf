output "web_server_public_ip" {
  description = "Public IP of the web (Node.js/React) server"
  value       = aws_instance.web.public_ip
}

output "web_server_public_dns" {
  description = "Public DNS name of the web server"
  value       = aws_instance.web.public_dns
}

output "web_server_private_ip" {
  description = "Private IP of the web server (used to scope MongoDB/ufw access on the db server)"
  value       = aws_instance.web.private_ip
}

output "db_server_private_ip" {
  description = "Private IP of the MongoDB server (reachable only via the web server)"
  value       = aws_instance.db.private_ip
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}
